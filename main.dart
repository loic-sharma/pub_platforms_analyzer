/// Crawls pub.dev and writes ONE JSON line per package to a single JSONL file.
///
/// For every package: fetch metadata (pubspec of every version comes for free).
/// For plugins (or every package with --all): download the latest archive,
/// verify its sha256, and list its tar entries in memory. Nothing is extracted
/// and no per-package files are written.
///
/// Usage:
///   dart run main.dart --out pub.jsonl [--concurrency 32] [--all]
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

late final http.Client _client;

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('out', defaultsTo: 'pub.jsonl')
    ..addOption('failures', defaultsTo: 'failures.jsonl')
    ..addOption('concurrency', defaultsTo: '32')
    ..addFlag('all', help: 'List archives of every package, not just plugins.');
  final opts = parser.parse(args);
  final concurrency = int.parse(opts['concurrency'] as String);
  final listAll = opts['all'] as bool;

  // One shared client: connections are kept alive and reused.
  _client = IOClient(HttpClient()
    ..maxConnectionsPerHost = concurrency
    ..userAgent = _userAgent
    ..connectionTimeout = const Duration(seconds: 30));

  final outFile = File(opts['out'] as String);
  final done = await _loadDone(outFile);
  final out = outFile.openWrite(mode: FileMode.append);
  final failures =
      File(opts['failures'] as String).openWrite(mode: FileMode.append);

  final names = await _packageNames();
  final todo = names.where((n) => !done.contains(n)).toList();
  stdout.writeln('${names.length} packages, ${done.length} already done, '
      '${todo.length} to go.');

  final pool = Pool(concurrency);
  final sw = Stopwatch()..start();
  var completed = 0;

  await Future.wait(todo.map((name) => pool.withResource(() async {
        try {
          final record = await _processPackage(name, listAll);
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
  _client.close();
  stdout.writeln('Done in ${sw.elapsed}.');
}

Future<Map<String, Object?>> _processPackage(String name, bool listAll) async {
  final meta = jsonDecode(utf8.decode(await _get(
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
    record.addAll(await _listArchive(
      Uri.parse(latest['archive_url'] as String),
      latest['archive_sha256'] as String?,
    ));
  }
  return record;
}

/// Downloads the compressed archive into memory (typically KBs to a few MB),
/// checks its hash, then streams through gzip + tar without extracting.
/// Buffering the *compressed* bytes keeps retries clean: a dropped connection
/// is simply retried, and nothing partial is ever written.
Future<Map<String, Object?>> _listArchive(Uri url, String? expectedSha) async {
  final bytes = await _get(url);
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

/// GET with status checking and exponential backoff on transient failures.
Future<Uint8List> _get(Uri url, {Map<String, String>? headers}) async {
  const maxAttempts = 5;
  for (var attempt = 1;; attempt++) {
    try {
      final res = await _client
          .get(url, headers: headers)
          .timeout(const Duration(minutes: 2));
      if (res.statusCode == 200) return res.bodyBytes;
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
    final delayMs = 500 * pow(2, attempt) + Random().nextInt(500);
    await Future<void>.delayed(Duration(milliseconds: delayMs.toInt()));
  }
}

Future<List<String>> _packageNames() async {
  final body = await _get(Uri.https('pub.dev', '/api/package-names'));
  final json = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
  return (json['packages'] as List).cast<String>();
}

/// Reads ids already in the output so a restart resumes where it stopped.
/// If the last run died mid-line, truncates the partial line first.
Future<Set<String>> _loadDone(File file) async {
  final done = <String>{};
  if (!await file.exists()) return done;

  final bytes = await file.readAsBytes();
  final lastNewline = bytes.lastIndexOf(10);
  if (lastNewline != bytes.length - 1) {
    final raf = await file.open(mode: FileMode.append);
    await raf.truncate(lastNewline + 1);
    await raf.close();
  }

  final text = utf8.decode(bytes.sublist(0, lastNewline + 1));
  for (final line in const LineSplitter().convert(text)) {
    if (line.isEmpty) continue;
    done.add((jsonDecode(line) as Map<String, dynamic>)['id'] as String);
  }
  return done;
}
