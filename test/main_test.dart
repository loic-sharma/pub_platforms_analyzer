import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:tar/tar.dart';
import 'package:test/test.dart';

import '../main.dart';

Duration _fastBackoff(int _) => const Duration(milliseconds: 5);

Future<Directory> createTempDir() async {
  final dir = await Directory.systemTemp.createTemp('pub_insights_test_');
  addTearDown(() => dir.delete(recursive: true));
  return dir;
}

Future<Uri> startServer(
  FutureOr<void> Function(HttpRequest req) handler, {
  bool autoCompress = true,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.autoCompress = autoCompress;
  addTearDown(() => server.close(force: true));
  server.listen((req) => handler(req));
  return Uri(scheme: 'http', host: server.address.address, port: server.port);
}

Lane createTestLane(int slots) {
  final lane = createLane(slots);
  addTearDown(lane.client.close);
  return lane;
}

TarEntry tarFile(String name, String content) =>
    TarEntry.data(TarHeader(name: name, mode: 420), utf8.encode(content));

Future<Uint8List> buildTarGz(List<TarEntry> entries) async {
  final builder = BytesBuilder(copy: false);
  await Stream<TarEntry>.fromIterable(entries)
      .transform(tarWriter)
      .transform(gzip.encoder)
      .forEach(builder.add);
  return builder.takeBytes();
}

String packageMetaJson(
  String name, {
  String version = '1.0.0',
  bool isPlugin = false,
  bool? isDiscontinued,
  String? archiveUrl,
  String? archiveSha,
  List<String>? versions,
  Map<String, Object?> extraPubspec = const {},
}) {
  return jsonEncode({
    'name': name,
    if (isDiscontinued != null) 'isDiscontinued': isDiscontinued,
    'latest': {
      'version': version,
      'published': '2026-01-01T00:00:00Z',
      if (archiveUrl != null) 'archive_url': archiveUrl,
      if (archiveSha != null) 'archive_sha256': archiveSha,
      'pubspec': {
        'name': name,
        'version': version,
        if (isPlugin)
          'flutter': {
            'plugin': {
              'platforms': {
                'android': {'package': 'com.example.$name'},
              },
            },
          },
        ...extraPubspec,
      },
    },
    'versions': [
      for (final v in versions ?? [version]) {'version': v},
    ],
  });
}

Future<Process> startCli(
  Uri baseUri,
  Directory dir, [
  List<String> extraArgs = const [],
]) async {
  final proc = await Process.start(Platform.resolvedExecutable, [
    'main.dart',
    '--base-url',
    baseUri.toString(),
    '--out',
    '${dir.path}/out.jsonl',
    '--failures',
    '${dir.path}/failures.jsonl',
    ...extraArgs,
  ]);
  addTearDown(() => proc.kill(ProcessSignal.sigkill));
  return proc;
}

void main() {
  group('snakeCase', () {
    test('converts camelCase and digit runs to snake_case', () {
      expect(snakeCase('grantedPoints'), 'granted_points');
      expect(snakeCase('maxPoints'), 'max_points');
      expect(snakeCase('likeCount'), 'like_count');
      expect(snakeCase('downloadCount30Days'), 'download_count_30_days');
      expect(snakeCase('tags'), 'tags');
      expect(snakeCase('already_snake'), 'already_snake');
      expect(snakeCase('foo2Bar'), 'foo_2_bar');
      expect(snakeCase(''), '');
    });
  });

  group('chunks', () {
    test('splits into zero-copy views of at most size', () {
      final data = Uint8List.fromList([0, 1, 2, 3, 4, 5, 6]);
      final parts = chunks(data, 3).toList();
      expect(parts.map((p) => p.toList()).toList(), [
        [0, 1, 2],
        [3, 4, 5],
        [6],
      ]);
      // Views share the underlying buffer without copying.
      data[0] = 99;
      data[6] = 77;
      expect(parts[0][0], 99);
      expect(parts[2][0], 77);
    });

    test('handles empty, exact multiples, and larger chunk sizes', () {
      expect(chunks(Uint8List(0), 4).toList(), isEmpty);
      final data = Uint8List.fromList([1, 2, 3, 4]);
      expect(chunks(data, 2).map((p) => p.toList()).toList(), [
        [1, 2],
        [3, 4],
      ]);
      expect(chunks(data, 10).map((p) => p.toList()).toList(), [
        [1, 2, 3, 4],
      ]);
    });
  });

  group('loadDone', () {
    test('handles missing and empty files', () async {
      final dir = await createTempDir();
      final missing = File('${dir.path}/missing.jsonl');
      expect(await loadDone(missing), isEmpty);
      expect(await missing.exists(), isFalse);

      final empty = await File('${dir.path}/empty.jsonl').create();
      expect(await loadDone(empty), isEmpty);
      expect(await empty.length(), 0);
    });

    test('reads ids via fast prefix, JSON fallback, and skips blank lines',
        () async {
      final dir = await createTempDir();
      final file = File('${dir.path}/out.jsonl');
      await file.writeAsString(
        '{"id":"alpha","version":"1.0.0"}\n'
        '\n'
        '{"version":"2.0.0","id":"beta"}\n'
        '{"id":"gamma_2","is_plugin":true}\n',
      );
      expect(await loadDone(file), {'alpha', 'beta', 'gamma_2'});
    });

    test(
        'truncates trailing partial line and preserves complete lines verbatim',
        () async {
      final dir = await createTempDir();
      final file = File('${dir.path}/partial.jsonl');
      const valid = '{"id":"one","v":1}\n{"id":"two","v":2}\n';
      await file.writeAsString('$valid{"id":"three","v":');

      expect(await loadDone(file), {'one', 'two'});
      expect(await file.readAsString(), valid);
    });

    test('truncates file to empty when single line has no trailing newline',
        () async {
      final dir = await createTempDir();
      final file = File('${dir.path}/single_partial.jsonl');
      await file.writeAsString('{"id":"truncated"');

      expect(await loadDone(file), isEmpty);
      expect(await file.length(), 0);
    });

    test('handles partial line longer than 64 KiB backwards scan chunk',
        () async {
      final dir = await createTempDir();
      final file = File('${dir.path}/large_partial.jsonl');
      const valid = '{"id":"kept_pkg","version":"1.0.0"}\n';
      await file.writeAsString('$valid{"id":"partial","pad":"${'x' * 140000}"');

      expect(await loadDone(file), {'kept_pkg'});
      expect(await file.readAsString(), valid);
    });
  });

  group('listArchive', () {
    test('lists entries, maps types, extracts pubspec.yaml, verifies sha256',
        () async {
      const rawPubspec = '# Comment preserved\nname: demo\nversion: 1.0.0\n';
      final bytes = await buildTarGz([
        TarEntry.data(
          TarHeader(name: 'lib/', mode: 493, typeFlag: TypeFlag.dir),
          const [],
        ),
        tarFile('lib/demo.dart', 'void main() {}\n'),
        tarFile('pubspec.yaml', rawPubspec),
        TarEntry.data(
          TarHeader(
            name: 'lib/alias.dart',
            mode: 420,
            typeFlag: TypeFlag.symlink,
            linkName: 'demo.dart',
          ),
          const [],
        ),
        TarEntry.data(
          TarHeader(
            name: 'lib/hard.dart',
            mode: 420,
            typeFlag: TypeFlag.link,
            linkName: 'lib/demo.dart',
          ),
          const [],
        ),
      ]);
      final digest = sha256.convert(bytes).toString();

      final result =
          await listArchive(bytes, 'https://example.test/demo.tar.gz', digest);
      expect(result['archive_bytes'], bytes.length);
      expect(result['pubspec_yaml'], rawPubspec);
      expect(result['entries'], [
        {'name': 'lib/', 'size': 0, 'type': 'dir'},
        {'name': 'lib/demo.dart', 'size': 15, 'type': 'file'},
        {'name': 'pubspec.yaml', 'size': rawPubspec.length, 'type': 'file'},
        {'name': 'lib/alias.dart', 'size': 0, 'type': 'symlink'},
        {'name': 'lib/hard.dart', 'size': 0, 'type': 'link'},
      ]);
    });

    test('returns null pubspec_yaml when archive has no pubspec.yaml',
        () async {
      final bytes = await buildTarGz([tarFile('README.md', 'hi')]);
      final result =
          await listArchive(bytes, 'https://example.test/a.tar.gz', null);
      expect(result['pubspec_yaml'], isNull);
      expect(result['entries'], [
        {'name': 'README.md', 'size': 2, 'type': 'file'},
      ]);
    });

    test('throws StateError on sha256 mismatch and throws on corrupt gzip',
        () async {
      final bytes = await buildTarGz([tarFile('a.txt', 'x')]);
      await expectLater(
        listArchive(bytes, 'https://example.test/bad.tar.gz', '0000'),
        throwsA(isA<StateError>()
            .having((e) => e.message, 'message', contains('sha256 mismatch'))),
      );
      await expectLater(
        listArchive(Uint8List.fromList([1, 2, 3, 4, 5]),
            'https://example.test/corrupt.tar.gz', null),
        throwsA(anything),
      );
    });
  });

  group('getBytes & Lane', () {
    test('returns body on 200 and sends User-Agent and custom headers',
        () async {
      String? seenUserAgent;
      String? seenAccept;
      final baseUri = await startServer((req) async {
        seenUserAgent = req.headers.value(HttpHeaders.userAgentHeader);
        seenAccept = req.headers.value(HttpHeaders.acceptHeader);
        req.response.write('hello');
        await req.response.close();
      });

      final lane = createTestLane(1);
      final bytes = await Crawler(baseUri: baseUri).getBytes(
        lane,
        baseUri.resolve('/ok'),
        headers: {'accept': 'application/vnd.pub.v2+json'},
      );
      expect(utf8.decode(bytes), 'hello');
      expect(seenUserAgent, 'pub_platforms_analyzer/1.0');
      expect(seenAccept, 'application/vnd.pub.v2+json');
    });

    test('does not retry non-transient 4xx status codes', () async {
      var hits = 0;
      final baseUri = await startServer((req) async {
        hits++;
        req.response
          ..statusCode = 404
          ..write('not found');
        await req.response.close();
      });

      final lane = createTestLane(1);
      await expectLater(
        Crawler(backoffDelay: _fastBackoff)
            .getBytes(lane, baseUri.resolve('/missing')),
        throwsA(isA<HttpStatusException>()
            .having((e) => e.statusCode, 'statusCode', 404)),
      );
      expect(hits, 1);
    });

    test('retries 429 and 5xx and succeeds once server recovers', () async {
      var hits = 0;
      const statuses = [429, 503, 500, 200];
      final baseUri = await startServer((req) async {
        final status = statuses[hits++];
        req.response
          ..statusCode = status
          ..write(status == 200 ? 'recovered' : 'retry me');
        await req.response.close();
      });

      final lane = createTestLane(1);
      final bytes = await Crawler(backoffDelay: _fastBackoff)
          .getBytes(lane, baseUri.resolve('/flaky'));
      expect(utf8.decode(bytes), 'recovered');
      expect(hits, 4);
    });

    test('throws HttpStatusException after exhausting 5 transient attempts',
        () async {
      var hits = 0;
      final baseUri = await startServer((req) async {
        hits++;
        req.response
          ..statusCode = 503
          ..write('down');
        await req.response.close();
      });

      final lane = createTestLane(1);
      await expectLater(
        Crawler(backoffDelay: _fastBackoff)
            .getBytes(lane, baseUri.resolve('/down')),
        throwsA(isA<HttpStatusException>()
            .having((e) => e.statusCode, 'statusCode', 503)),
      );
      expect(hits, 5);
    });

    test('retries dropped socket connection and succeeds', () async {
      var hits = 0;
      final baseUri = await startServer((req) async {
        hits++;
        if (hits == 1) {
          final socket = await req.response.detachSocket(writeHeaders: false);
          socket.destroy();
          return;
        }
        req.response.write('ok after drop');
        await req.response.close();
      });

      final lane = createTestLane(1);
      final bytes = await Crawler(backoffDelay: _fastBackoff)
          .getBytes(lane, baseUri.resolve('/drop'));
      expect(utf8.decode(bytes), 'ok after drop');
      expect(hits, 2);
    });

    test('send idle timeout aborts request and frees the sole connection',
        () async {
      final baseUri = await startServer((req) async {
        if (req.uri.path == '/stall') {
          await Completer<void>().future;
        }
        req.response.write('fast');
        await req.response.close();
      });

      final lane = createTestLane(1);
      await expectLater(
        Crawler(
          idleTimeout: const Duration(milliseconds: 100),
          backoffDelay: (_) => Duration.zero,
        ).getBytes(lane, baseUri.resolve('/stall')),
        throwsA(isA<TimeoutException>()),
      );

      final bytes = await Crawler(idleTimeout: const Duration(seconds: 5))
          .getBytes(lane, baseUri.resolve('/fast'));
      expect(utf8.decode(bytes), 'fast');
    });

    test('body stream idle timeout aborts and frees connection', () async {
      final baseUri = await startServer((req) async {
        if (req.uri.path == '/body-stall') {
          req.response
            ..statusCode = 200
            ..bufferOutput = false
            ..write('partial');
          await req.response.flush();
          await Completer<void>().future;
        }
        req.response.write('after-body-stall');
        await req.response.close();
      }, autoCompress: false);

      final lane = createTestLane(1);
      await expectLater(
        Crawler(
          idleTimeout: const Duration(milliseconds: 150),
          backoffDelay: (_) => Duration.zero,
        ).getBytes(lane, baseUri.resolve('/body-stall')),
        throwsA(isA<TimeoutException>()),
      );

      final bytes = await Crawler(idleTimeout: const Duration(seconds: 5))
          .getBytes(lane, baseUri.resolve('/ok'));
      expect(utf8.decode(bytes), 'after-body-stall');
    });

    test('slow steady stream exceeding idleTimeout in total succeeds',
        () async {
      var hits = 0;
      final baseUri = await startServer((req) async {
        hits++;
        req.response
          ..statusCode = 200
          ..bufferOutput = false;
        for (var i = 0; i < 8; i++) {
          req.response.write('chunk$i-');
          await req.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        await req.response.close();
      }, autoCompress: false);

      // Total stream duration (~400 ms) > idleTimeout (250 ms), while the gap
      // between chunks (~50 ms) stays well below idleTimeout.
      final lane = createTestLane(1);
      final bytes = await Crawler(
        idleTimeout: const Duration(milliseconds: 250),
        backoffDelay: _fastBackoff,
      ).getBytes(lane, baseUri.resolve('/slow-steady'));
      expect(hits, 1);
      expect(
        utf8.decode(bytes),
        'chunk0-chunk1-chunk2-chunk3-chunk4-chunk5-chunk6-chunk7-',
      );
    });

    test('non-200 stalled body drain times out without leaking connection',
        () async {
      var hits = 0;
      final baseUri = await startServer((req) async {
        hits++;
        if (hits == 1) {
          req.response
            ..statusCode = 503
            ..bufferOutput = false
            ..write('err');
          await req.response.flush();
          await Completer<void>().future;
        }
        req.response.write('ok');
        await req.response.close();
      }, autoCompress: false);

      final lane = createTestLane(1);
      final bytes = await Crawler(
        idleTimeout: const Duration(milliseconds: 150),
        backoffDelay: (_) => Duration.zero,
      ).getBytes(lane, baseUri.resolve('/drain-stall'));
      expect(utf8.decode(bytes), 'ok');
      expect(hits, 2);
    });

    test('stopRequested skips queued work and interrupts retry backoff',
        () async {
      var hits = 0;
      final baseUri = await startServer((req) async {
        hits++;
        req.response
          ..statusCode = 503
          ..write('busy');
        await req.response.close();
      });

      final lane = createTestLane(1);
      // Already stopped: never hits server.
      await expectLater(
        Crawler(stopRequested: Completer<void>()..complete())
            .getBytes(lane, baseUri.resolve('/a')),
        throwsA(isA<StoppedException>()),
      );
      expect(hits, 0);

      // Stop triggered after entering a 30 s backoff wakes promptly.
      final stopDuringBackoff = Completer<void>();
      final sw = Stopwatch()..start();
      await expectLater(
        Crawler(
          stopRequested: stopDuringBackoff,
          backoffDelay: (_) {
            Timer(const Duration(milliseconds: 20), stopDuringBackoff.complete);
            return const Duration(seconds: 30);
          },
        ).getBytes(lane, baseUri.resolve('/b')),
        throwsA(isA<StoppedException>()),
      );
      expect(hits, 1);
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
    });
  });

  group('fetchScore & processPackage', () {
    late Uri baseUri;
    late Uint8List sampleArchive;
    late String sampleArchiveSha;
    late List<String> requestedPaths;

    setUp(() async {
      requestedPaths = [];
      sampleArchive = await buildTarGz([
        tarFile('pubspec.yaml', 'name: my_plugin\nversion: 1.2.3\n'),
        tarFile('lib/my_plugin.dart', '// plugin\n'),
      ]);
      sampleArchiveSha = sha256.convert(sampleArchive).toString();

      baseUri = await startServer((req) async {
        requestedPaths.add(req.uri.path);
        switch (req.uri.path) {
          case '/api/packages/plain_pkg':
            req.response.write(packageMetaJson(
              'plain_pkg',
              archiveUrl:
                  baseUri.resolve('/archives/plain_pkg.tar.gz').toString(),
              archiveSha: sampleArchiveSha,
              versions: ['0.9.0', '1.0.0'],
              extraPubspec: {'flutter': 'not-a-map'},
            ));
          case '/api/packages/plain_pkg/score':
            req.response.write(jsonEncode({
              'grantedPoints': 150,
              'maxPoints': 160,
              'likeCount': 42,
              'downloadCount30Days': 12345,
              'tags': ['sdk:dart', 'license:mit'],
            }));
          case '/api/packages/my_plugin':
            req.response.write(packageMetaJson(
              'my_plugin',
              version: '1.2.3',
              isPlugin: true,
              isDiscontinued: true,
              archiveUrl:
                  baseUri.resolve('/archives/my_plugin.tar.gz').toString(),
              archiveSha: sampleArchiveSha,
            ));
          case '/api/packages/my_plugin/score':
            req.response.statusCode = 404;
          case '/api/packages/forbidden/score':
            req.response.statusCode = 403;
          case '/archives/plain_pkg.tar.gz' || '/archives/my_plugin.tar.gz':
            req.response.add(sampleArchive);
          default:
            req.response.statusCode = 404;
        }
        await req.response.close();
      });
    });

    test('fetchScore converts keys to snake_case, returns null on 404',
        () async {
      final crawler = Crawler(baseUri: baseUri);
      final metaLane = createTestLane(4);

      expect(await crawler.fetchScore(metaLane, 'plain_pkg'), {
        'granted_points': 150,
        'max_points': 160,
        'like_count': 42,
        'download_count_30_days': 12345,
        'tags': ['sdk:dart', 'license:mit'],
      });
      expect(await crawler.fetchScore(metaLane, 'my_plugin'), isNull);
      await expectLater(
        crawler.fetchScore(metaLane, 'forbidden'),
        throwsA(isA<HttpStatusException>()
            .having((e) => e.statusCode, 'statusCode', 403)),
      );
    });

    test('regular package without --all skips archive and keeps id first',
        () async {
      final record = await Crawler(baseUri: baseUri).processPackage(
        'plain_pkg',
        false,
        createTestLane(4),
        createTestLane(2),
      );

      expect(record.keys.first, 'id');
      expect(jsonEncode(record), startsWith('{"id":"plain_pkg",'));
      expect(record['version'], '1.0.0');
      expect(record['is_plugin'], isFalse);
      expect(record['is_discontinued'], isFalse);
      expect(record['version_count'], 2);
      expect((record['score'] as Map)['download_count_30_days'], 12345);
      expect(record['entries'], isNull);
      expect(record['pubspec_yaml'], isNull);
      expect(record.containsKey('archive_bytes'), isFalse);
      expect(requestedPaths, isNot(contains('/archives/plain_pkg.tar.gz')));
    });

    test('plugin package and --all download and list archives', () async {
      final crawler = Crawler(baseUri: baseUri);
      final metaLane = createTestLane(4);
      final archiveLane = createTestLane(2);

      final plugin = await crawler.processPackage(
        'my_plugin',
        false,
        metaLane,
        archiveLane,
      );
      expect(plugin.keys.first, 'id');
      expect(plugin['is_plugin'], isTrue);
      expect(plugin['is_discontinued'], isTrue);
      expect(plugin['score'], isNull);
      expect(plugin['archive_bytes'], sampleArchive.length);
      expect(plugin['pubspec_yaml'], 'name: my_plugin\nversion: 1.2.3\n');
      expect(plugin['entries'], hasLength(2));

      final plainWithAll = await crawler.processPackage(
        'plain_pkg',
        true,
        metaLane,
        archiveLane,
      );
      expect(plainWithAll['is_plugin'], isFalse);
      expect(plainWithAll['archive_bytes'], sampleArchive.length);
      expect(plainWithAll['entries'], hasLength(2));
      expect(requestedPaths, contains('/archives/plain_pkg.tar.gz'));
    });
  });

  group('Crawler.run & resume', () {
    test('creates no output files if fetching package list fails', () async {
      final dir = await createTempDir();
      final baseUri = await startServer((req) async {
        req.response.statusCode = 403;
        await req.response.close();
      });

      final outFile = File('${dir.path}/pub.jsonl');
      final failFile = File('${dir.path}/failures.jsonl');
      await expectLater(
        Crawler(baseUri: baseUri, backoffDelay: _fastBackoff, log: (_) {})
            .run(outFile: outFile, failuresFile: failFile),
        throwsA(isA<HttpStatusException>()),
      );
      expect(await outFile.exists(), isFalse);
      expect(await failFile.exists(), isFalse);
    });

    test('crawls, records failures, and resumes cleanly after a partial line',
        () async {
      final dir = await createTempDir();
      final archiveBytes =
          await buildTarGz([tarFile('pubspec.yaml', 'name: p\n')]);
      final archiveSha = sha256.convert(archiveBytes).toString();
      var packageList = ['pkg_ok', 'pkg_plugin', 'pkg_broken'];
      final metaHits = <String, int>{};

      late Uri baseUri;
      baseUri = await startServer((req) async {
        final path = req.uri.path;
        if (path == '/api/package-names') {
          req.response.write(jsonEncode({'packages': packageList}));
        } else if (path == '/api/packages/pkg_broken') {
          metaHits['pkg_broken'] = (metaHits['pkg_broken'] ?? 0) + 1;
          req.response.statusCode = 404;
        } else if (path.startsWith('/api/packages/') &&
            path.endsWith('/score')) {
          req.response
              .write(jsonEncode({'grantedPoints': 100, 'likeCount': 5}));
        } else if (path.startsWith('/api/packages/')) {
          final name = path.substring('/api/packages/'.length);
          metaHits[name] = (metaHits[name] ?? 0) + 1;
          req.response.write(packageMetaJson(
            name,
            isPlugin: name == 'pkg_plugin',
            archiveUrl: baseUri.resolve('/archives/$name.tar.gz').toString(),
            archiveSha: archiveSha,
          ));
        } else if (path.startsWith('/archives/')) {
          req.response.add(archiveBytes);
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
      });

      final outFile = File('${dir.path}/pub.jsonl');
      final failFile = File('${dir.path}/failures.jsonl');
      final crawler = Crawler(
        baseUri: baseUri,
        backoffDelay: _fastBackoff,
        log: (_) {},
      );

      final first = await crawler.run(
        outFile: outFile,
        failuresFile: failFile,
        concurrency: 2,
        archiveConcurrency: 1,
      );
      expect(first, (written: 2, failed: 1, total: 3, skipped: 0));

      final originalText = await outFile.readAsString();
      final lines = const LineSplitter().convert(originalText);
      expect(lines, hasLength(2));
      for (final line in lines) {
        expect(line, startsWith('{"id":"'));
      }
      final byId = {
        for (final l in lines)
          (jsonDecode(l) as Map<String, dynamic>)['id'] as String:
              jsonDecode(l) as Map<String, dynamic>,
      };
      expect(byId['pkg_ok']!['entries'], isNull);
      expect(byId['pkg_plugin']!['entries'], hasLength(1));

      final failureLines =
          const LineSplitter().convert(await failFile.readAsString());
      expect(failureLines, hasLength(1));
      expect((jsonDecode(failureLines.single) as Map)['id'], 'pkg_broken');

      // Simulate crash leaving a partial line, then add a new package.
      await outFile.writeAsString('$originalText{"id":"pkg_new","partial');
      packageList = ['pkg_ok', 'pkg_plugin', 'pkg_new'];
      metaHits.clear();

      final second = await crawler.run(
        outFile: outFile,
        failuresFile: failFile,
        concurrency: 2,
        archiveConcurrency: 1,
      );
      expect(second, (written: 1, failed: 0, total: 3, skipped: 2));
      expect(metaHits, {'pkg_new': 1});

      final updatedText = await outFile.readAsString();
      expect(updatedText, startsWith(originalText));
      final updatedIds = const LineSplitter()
          .convert(updatedText)
          .map((l) => (jsonDecode(l) as Map<String, dynamic>)['id'] as String)
          .toList();
      expect(updatedIds.toSet(), {'pkg_ok', 'pkg_plugin', 'pkg_new'});
      expect(updatedIds.length, 3);
    });
  });

  group('CLI subprocess & signal handling', () {
    test('runs end-to-end via CLI arguments including --all', () async {
      final dir = await createTempDir();
      final archiveBytes =
          await buildTarGz([tarFile('pubspec.yaml', 'name: cli_pkg\n')]);
      final archiveSha = sha256.convert(archiveBytes).toString();

      late Uri baseUri;
      baseUri = await startServer((req) async {
        switch (req.uri.path) {
          case '/api/package-names':
            req.response.write(jsonEncode({
              'packages': ['cli_pkg']
            }));
          case '/api/packages/cli_pkg':
            req.response.write(packageMetaJson(
              'cli_pkg',
              version: '0.1.0',
              archiveUrl:
                  baseUri.resolve('/archives/cli_pkg.tar.gz').toString(),
              archiveSha: archiveSha,
            ));
          case '/api/packages/cli_pkg/score':
            req.response.write(jsonEncode({'grantedPoints': 120}));
          case '/archives/cli_pkg.tar.gz':
            req.response.add(archiveBytes);
          default:
            req.response.statusCode = 404;
        }
        await req.response.close();
      });

      final proc = await startCli(baseUri, dir, [
        '--concurrency',
        '2',
        '--archive-concurrency',
        '1',
        '--all',
      ]);
      final (code, stdoutText, stderrText) = await (
        proc.exitCode,
        proc.stdout.transform(utf8.decoder).join(),
        proc.stderr.transform(utf8.decoder).join(),
      ).wait.timeout(const Duration(seconds: 25));

      expect(code, 0, reason: stderrText);
      expect(stdoutText, contains('1 written, 0 failed of 1'));
      final row = jsonDecode(await File('${dir.path}/out.jsonl').readAsString())
          as Map<String, dynamic>;
      expect(row['id'], 'cli_pkg');
      expect(row['archive_bytes'], archiveBytes.length);
      expect(await File('${dir.path}/failures.jsonl').readAsString(), isEmpty);
    });

    test(
      'first SIGTERM finishes in-flight request cleanly and exits 0',
      () async {
        final dir = await createTempDir();
        final scoreStarted = Completer<void>();
        final releaseScore = Completer<void>();
        addTearDown(() {
          if (!releaseScore.isCompleted) releaseScore.complete();
        });

        final baseUri = await startServer((req) async {
          final path = req.uri.path;
          if (path == '/api/package-names') {
            req.response.write(jsonEncode({
              'packages': ['first_pkg', 'second_pkg', 'third_pkg'],
            }));
          } else if (path == '/api/packages/first_pkg/score') {
            if (!scoreStarted.isCompleted) scoreStarted.complete();
            await releaseScore.future;
            req.response.write(jsonEncode({'grantedPoints': 140}));
          } else if (path.startsWith('/api/packages/') &&
              !path.endsWith('/score')) {
            req.response.write(
              packageMetaJson(path.substring('/api/packages/'.length)),
            );
          } else {
            req.response.statusCode = 404;
          }
          await req.response.close();
        });

        final proc = await startCli(baseUri, dir, [
          '--concurrency',
          '1',
          '--archive-concurrency',
          '1',
        ]);
        final stdoutDone = proc.stdout.transform(utf8.decoder).join();
        final stderrBuf = StringBuffer();
        final gotStopNotice = Completer<void>();
        final stderrDone = proc.stderr.transform(utf8.decoder).listen((chunk) {
          stderrBuf.write(chunk);
          if (stderrBuf.toString().contains('finishing requests') &&
              !gotStopNotice.isCompleted) {
            gotStopNotice.complete();
          }
        }).asFuture<void>();

        await scoreStarted.future.timeout(const Duration(seconds: 25));
        proc.kill(ProcessSignal.sigterm);
        await gotStopNotice.future.timeout(const Duration(seconds: 25));
        releaseScore.complete();

        final (code, stdoutText, _) = await (
          proc.exitCode,
          stdoutDone,
          stderrDone,
        ).wait.timeout(const Duration(seconds: 25));

        expect(code, 0, reason: 'stderr: $stderrBuf');
        expect(stdoutText, contains('Stopped after'));
        expect(stdoutText, contains('1 written, 0 failed of 3'));

        final outText = await File('${dir.path}/out.jsonl').readAsString();
        expect(outText.endsWith('\n'), isTrue);
        final lines = const LineSplitter().convert(outText);
        expect(lines, hasLength(1));
        expect((jsonDecode(lines.single) as Map)['id'], 'first_pkg');
        expect(
            await File('${dir.path}/failures.jsonl').readAsString(), isEmpty);
      },
      skip: Platform.isWindows ? 'SIGTERM cannot be watched on Windows' : false,
    );

    test(
      'second SIGTERM exits immediately with code 143',
      () async {
        final dir = await createTempDir();
        final requestStarted = Completer<void>();

        final baseUri = await startServer((req) async {
          if (req.uri.path == '/api/package-names') {
            req.response.write(jsonEncode({
              'packages': ['stuck_pkg']
            }));
            await req.response.close();
            return;
          }
          if (!requestStarted.isCompleted) requestStarted.complete();
          // Hold open without writing; server.close(force: true) cleans up.
          await Completer<void>().future;
        });

        final proc = await startCli(baseUri, dir, ['--concurrency', '1']);
        final stdoutDone = proc.stdout.drain<void>();
        final stderrBuf = StringBuffer();
        final gotFirstNotice = Completer<void>();
        final stderrDone = proc.stderr.transform(utf8.decoder).listen((chunk) {
          stderrBuf.write(chunk);
          if (stderrBuf.toString().contains('finishing requests') &&
              !gotFirstNotice.isCompleted) {
            gotFirstNotice.complete();
          }
        }).asFuture<void>();

        await requestStarted.future.timeout(const Duration(seconds: 25));
        proc.kill(ProcessSignal.sigterm);
        await gotFirstNotice.future.timeout(const Duration(seconds: 25));
        proc.kill(ProcessSignal.sigterm);

        final (code, _, _) = await (
          proc.exitCode,
          stdoutDone,
          stderrDone,
        ).wait.timeout(const Duration(seconds: 25));
        expect(code, 143, reason: 'stderr: $stderrBuf');
      },
      skip: Platform.isWindows ? 'SIGTERM cannot be watched on Windows' : false,
    );
  });
}
