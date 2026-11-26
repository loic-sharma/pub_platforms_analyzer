/// Crawls pub.dev and writes ONE JSON line per package to a single JSONL file.
///
/// For every package: fetch metadata (pubspec of every version comes for free).
/// For plugins (or every package with --all): download the latest archive,
/// verify its sha256, and list its tar entries in memory. Nothing is extracted
/// and no per-package files are written.
///
/// Usage:
///   dart run main.dart --out pub.jsonl [--concurrency 32]
///       [--archive-concurrency 4] [--all]
///
/// Metadata requests are small and latency-bound; archive downloads are large
/// and bandwidth-bound. They run in separate pools on separate connections so
/// a few big archives can saturate the link without starving metadata.
///
/// Safe to stop and restart: packages already in the output file are skipped.
///
/// Query with DuckDB, e.g. top-level folders vs. declared platforms:
///   SELECT id,
///     list(DISTINCT split_part(e.name, '/', 1)) FILTER (WHERE e.name LIKE '%/%') AS top_dirs,
///     json_keys(any_value(pubspec), '$.flutter.plugin.platforms') AS declared
///   FROM (SELECT id, pubspec, unnest(entries) AS e
///         FROM read_json_auto('pub.jsonl') WHERE is_plugin)
///   GROUP BY id;
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:pool/pool.dart';
import 'package:tar/tar.dart';

const _userAgent = 'pub_insights/1.0 (+mailto:sharma.loic@gmail.com)';

/// A request fails if no bytes arrive for this long. Unlike a timeout on the
/// whole request, this never aborts a large archive that is still downloading.
const _idleTimeout = Duration(seconds: 60);

/// Separate clients so archive downloads never hold the connections that
/// metadata requests need. Connections are kept alive and reused.
late final http.Client _metaClient;
late final http.Client _archiveClient;

/// Fused decoder parses JSON straight from UTF-8 bytes, skipping the String.
final _jsonUtf8 = utf8.decoder.fuse(json.decoder);

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('out', defaultsTo: 'pub.jsonl')
    ..addOption('failures', defaultsTo: 'failures.jsonl')
    ..addOption('concurrency',
        defaultsTo: '32', help: 'Concurrent metadata requests.')
    ..addOption('archive-concurrency',
        defaultsTo: '4',
        help: 'Concurrent archive downloads. These are bandwidth-bound, so a '
            'few are enough to saturate the link.')
    ..addFlag('all', help: 'List archives of every package, not just plugins.');
  final opts = parser.parse(args);
  final concurrency = int.parse(opts['concurrency'] as String);
  final archiveConcurrency = int.parse(opts['archive-concurrency'] as String);
  final listAll = opts['all'] as bool;

  http.Client newClient(int maxConnections) => IOClient(HttpClient()
    ..maxConnectionsPerHost = maxConnections
    ..userAgent = _userAgent
    ..connectionTimeout = const Duration(seconds: 30));
  _metaClient = newClient(concurrency);
  _archiveClient = newClient(archiveConcurrency);

  final outFile = File(opts['out'] as String);
  final done = await _loadDone(outFile);
  final out = outFile.openWrite(mode: FileMode.append);
  final failures =
      File(opts['failures'] as String).openWrite(mode: FileMode.append);

  final names = await _packageNames();
  final todo = names.where((n) => !done.contains(n)).toList();
  stdout.writeln('${names.length} packages, ${done.length} already done, '
      '${todo.length} to go.');

  final metaPool = Pool(concurrency);
  final archivePool = Pool(archiveConcurrency);
  // Bounds packages between "metadata started" and "line written", so records
  // waiting on the archive pool can't pile up in memory without limit.
  final inFlight = Pool(max(1000, concurrency + archiveConcurrency));
  final sw = Stopwatch()..start();
  var completed = 0;

  await Future.wait(todo.map((name) => inFlight.withResource(() async {
        try {
          final record =
              await _processPackage(name, listAll, metaPool, archivePool);
          // Single isolate: each writeln lands as one whole line.
          out.writeln(jsonEncode(record));
        } catch (e) {
          failures.writeln(jsonEncode({'id': name, 'error': '$e'}));
        }
        if (++completed % 500 == 0) {
          final rate = completed / max(1, sw.elapsed.inSeconds);
          stdout.writeln('$completed/${todo.length} '
              '(${rate.toStringAsFixed(1)}/s)');
        }
      })));

  await out.close();
  await failures.close();
  _metaClient.close();
  _archiveClient.close();
  stdout.writeln('Done in ${sw.elapsed}.');
}

Future<Map<String, Object?>> _processPackage(
    String name, bool listAll, Pool metaPool, Pool archivePool) async {
  final meta = _jsonUtf8.convert(await metaPool.withResource(() => _get(
        _metaClient,
        Uri.https('pub.dev', '/api/packages/$name'),
        headers: {'accept': 'application/vnd.pub.v2+json'},
      ))) as Map<String, dynamic>;

  final latest = meta['latest'] as Map<String, dynamic>;
  final pubspec = latest['pubspec'] as Map<String, dynamic>;
  final flutter = pubspec['flutter'];
  final isPlugin = flutter is Map && flutter['plugin'] != null;

  final record = <String, Object?>{
    'id': name,
    'version': latest['version'],
    'published': latest['published'],
    'is_plugin': isPlugin,
    'is_discontinued': meta['isDiscontinued'] ?? false,
    'version_count': (meta['versions'] as List).length,
    'pubspec': pubspec,
    'entries': null,
    'pubspec_yaml': null,
  };

  if (isPlugin || listAll) {
    // The metadata slot is already released, so this wait doesn't block
    // other packages' metadata.
    final bytes = await archivePool.withResource(
        () => _get(_archiveClient, Uri.parse(latest['archive_url'] as String)));
    record.addAll(await _listArchive(
      bytes,
      latest['archive_url'] as String,
      latest['archive_sha256'] as String?,
    ));
  }
  return record;
}

/// Checks the downloaded archive's hash, then streams through gzip + tar
/// without extracting. Buffering the *compressed* bytes (typically KBs to a
/// few MB) keeps retries clean: a dropped connection is simply retried, and
/// nothing partial is ever written.
Future<Map<String, Object?>> _listArchive(
    Uint8List bytes, String url, String? expectedSha) async {
  if (expectedSha != null && sha256.convert(bytes).toString() != expectedSha) {
    throw StateError('sha256 mismatch for $url');
  }

  final entries = <Map<String, Object?>>[];
  String? pubspecYaml;
  final reader =
      TarReader(Stream<List<int>>.value(bytes).transform(gzip.decoder));
  try {
    while (await reader.moveNext()) {
      final entry = reader.current;
      entries.add({
        'name': entry.name,
        'size': entry.size,
        'type': entry.type == TypeFlag.dir ? 'dir' : 'file',
      });
      // Keep the raw pubspec text too (comments, key order). Unread entry
      // contents are skipped automatically by moveNext().
      if (entry.name == 'pubspec.yaml') {
        pubspecYaml = await utf8.decodeStream(entry.contents);
      }
    }
  } finally {
    await reader.cancel();
  }

  return {
    'archive_bytes': bytes.length,
    'entries': entries,
    'pubspec_yaml': pubspecYaml,
  };
}

final _random = Random();

/// GET with status checking and exponential backoff on transient failures.
Future<Uint8List> _get(http.Client client, Uri url,
    {Map<String, String>? headers}) async {
  const maxAttempts = 5;
  for (var attempt = 1;; attempt++) {
    try {
      final req = http.Request('GET', url);
      if (headers != null) req.headers.addAll(headers);
      final res = await client.send(req).timeout(_idleTimeout);
      if (res.statusCode == 200) {
        final body = BytesBuilder(copy: false);
        await res.stream.timeout(_idleTimeout).forEach(body.add);
        return body.takeBytes();
      }
      // Drain so the connection can be reused.
      await res.stream.drain<void>().timeout(_idleTimeout);
      final transient = res.statusCode == 429 || res.statusCode >= 500;
      // Thrown as a StateError so the retry handlers below don't catch it.
      if (!transient || attempt == maxAttempts) {
        throw StateError('HTTP ${res.statusCode} for $url');
      }
    } on HttpException {
      if (attempt == maxAttempts) rethrow;
    } on SocketException {
      if (attempt == maxAttempts) rethrow;
    } on TimeoutException {
      if (attempt == maxAttempts) rethrow;
    } on http.ClientException {
      if (attempt == maxAttempts) rethrow;
    }
    final delayMs = 500 * pow(2, attempt) + _random.nextInt(500);
    await Future<void>.delayed(Duration(milliseconds: delayMs.toInt()));
  }
}

Future<List<String>> _packageNames() async {
  final body =
      await _get(_metaClient, Uri.https('pub.dev', '/api/package-names'));
  final json = _jsonUtf8.convert(body) as Map<String, dynamic>;
  return (json['packages'] as List).cast<String>();
}

/// Reads ids already in the output so a restart resumes where it stopped.
/// If the last run died mid-line, truncates the partial line first.
Future<Set<String>> _loadDone(File file) async {
  final done = <String>{};
  if (!await file.exists()) return done;

  // Find the last newline by scanning backwards, so a large output file is
  // never loaded into memory at once.
  final raf = await file.open(mode: FileMode.append);
  try {
    final length = await raf.length();
    var end = length;
    var lastNewline = -1;
    const chunkSize = 1 << 16;
    while (end > 0 && lastNewline < 0) {
      final start = max(0, end - chunkSize);
      await raf.setPosition(start);
      final chunk = await raf.read(end - start);
      final i = chunk.lastIndexOf(10);
      if (i >= 0) lastNewline = start + i;
      end = start;
    }
    if (lastNewline != length - 1) await raf.truncate(lastNewline + 1);
  } finally {
    await raf.close();
  }

  // Records are written with "id" first and package names never need JSON
  // escaping, so the id can be sliced out without decoding the whole line.
  const prefix = '{"id":"';
  await for (final line in file
      .openRead()
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    if (line.isEmpty) continue;
    final close =
        line.startsWith(prefix) ? line.indexOf('"', prefix.length) : -1;
    done.add(close > 0
        ? line.substring(prefix.length, close)
        : (jsonDecode(line) as Map<String, dynamic>)['id'] as String);
  }
  return done;
}
