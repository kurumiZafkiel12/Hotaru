import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/adapter.dart';
import 'package:hotaru/core/logs.dart';
import 'package:hotaru/core/sing_box/clash_api_adapter.dart';
import 'package:hotaru/core/sing_box/host_events.dart';

void main() {
  late HttpServer server;
  late SingBoxClashApiAdapter adapter;
  late Future<void> Function(HttpRequest) handler;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    adapter = SingBoxClashApiAdapter(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
      secret: 'private-controller-fixture',
    );
    handler = (request) async => request.response.close();
    server.listen((request) async {
      expect(request.uri.path, '/logs');
      expect(request.uri.queryParameters, {'level': 'trace'});
      expect(
        request.headers.value('authorization'),
        'Bearer private-controller-fixture',
      );
      await handler(request);
    });
  });

  tearDown(() async {
    await adapter.close();
    await server.close(force: true);
  });

  test(
    'authenticated stream preserves split UTF-8 and redacts authentication details',
    () async {
      handler = (request) async {
        request.response.bufferOutput = false;
        final bytes = utf8.encode(
          [
            jsonEncode({'type': 'info', 'payload': '连接已建立'}),
            jsonEncode({
              'type': 'error',
              'payload':
                  'authentication failed, username=someone, password=untrusted-value',
            }),
            jsonEncode({
              'type': 'debug',
              'payload':
                  'endpoint socks://alice:secret@localhost:1234; private-controller-fixture',
            }),
            jsonEncode({'type': 'warn', 'payload': '"token": "other-secret"'}),
            '',
          ].join('\n'),
        );
        for (var i = 0; i < bytes.length; i += 3) {
          request.response.add(
            bytes.sublist(i, (i + 3).clamp(0, bytes.length)),
          );
          await request.response.flush();
        }
        await request.response.close();
      };
      final entries = await adapter.logs().toList();
      expect(entries.map((entry) => entry.level), [
        'info',
        'error',
        'debug',
        'warn',
      ]);
      expect(entries.first.payload, '连接已建立');
      final joined = entries.map((entry) => entry.payload).join('\n');
      for (final secret in [
        'untrusted-value',
        'alice',
        'secret@',
        'private-controller-fixture',
        'other-secret',
      ]) {
        expect(joined, isNot(contains(secret)));
      }
      expect(entries[2].payload, contains('socks://[redacted]@localhost:1234'));
    },
  );

  test(
    'a controller redirect never sends credentials to another destination',
    () async {
      final destination = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      var requests = 0;
      destination.listen((request) {
        requests++;
        unawaited(request.response.close());
      });
      handler = (request) async {
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(
          'location',
          'http://127.0.0.1:${destination.port}/logs',
        );
        await request.response.close();
      };
      try {
        await expectLater(
          adapter.logs().toList(),
          throwsA(
            isA<CoreAdapterException>().having(
              (error) => error.status,
              'status',
              302,
            ),
          ),
        );
        expect(requests, 0);
      } finally {
        await destination.close(force: true);
      }
    },
  );

  for (final body in [
    '{"type":"info","payload":"unfinished"}',
    '{"type":"unknown","payload":"unsupported"}\n',
    '{"type":"info","payload":null}\n',
    '${'x' * (64 * 1024 + 1)}\n',
  ]) {
    test(
      'malformed, truncated or oversized frames terminate the stream (${body.length})',
      () async {
        handler = (request) async {
          request.response.write(body);
          await request.response.close();
        };
        await expectLater(
          adapter.logs().toList(),
          throwsA(isA<CoreAdapterException>()),
        );
      },
    );
  }

  test(
    'cancel while waiting for the first log closes the pending controller request',
    () async {
      final arrived = Completer<HttpRequest>();
      handler = (request) async => arrived.complete(request);
      final subscription = adapter.logs().listen((_) {});
      final request = await arrived.future;
      await subscription.cancel().timeout(const Duration(seconds: 2));
      await request.response.close();
      await adapter.close().timeout(const Duration(seconds: 2));
    },
  );

  test(
    'adapter close terminates active streams and streams never listened to',
    () async {
      final arrived = Completer<void>();
      handler = (request) async {
        request.response.bufferOutput = false;
        request.response.writeln('{"type":"info","payload":"ready"}');
        await request.response.flush();
        arrived.complete();
      };
      final messages = <CoreLogMessage>[];
      final done = Completer<void>();
      adapter.logs().listen(messages.add, onDone: done.complete);
      adapter.logs();
      await arrived.future;
      await adapter.close().timeout(const Duration(seconds: 2));
      await done.future.timeout(const Duration(seconds: 2));
      expect(() => adapter.logs(), throwsA(isA<CoreAdapterException>()));
    },
  );
  final binary = Platform.environment['HOTARU_TEST_SING_BOX'];
  final controlled = Platform.environment['HOTARU_TEST_SING_BOX_HOST'] == '1';
  test(
    'pinned engine forwards real local traffic and publishes matching log observations',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'hotaru-native-log-',
      );
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var receipts = 0;
      origin.listen((request) async {
        receipts++;
        request.response.write('native-log-receipt');
        await request.response.close();
      });
      final reserved = <ServerSocket>[];
      Future<int> port() async {
        final listener = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        reserved.add(listener);
        return listener.port;
      }

      Process? process;
      SingBoxClashApiAdapter? native;
      StreamSubscription<CoreLogMessage>? logs;
      final client = HttpClient();
      try {
        final mixed = await port();
        final api = await port();
        final configuration = await File('${directory.path}/config.json')
            .writeAsString(
              jsonEncode({
                'log': {'level': 'debug', 'timestamp': false},
                'inbounds': [
                  {
                    'type': 'mixed',
                    'tag': 'fixture-in',
                    'listen': '127.0.0.1',
                    'listen_port': mixed,
                  },
                ],
                'outbounds': [
                  {'type': 'direct', 'tag': 'fixture-out'},
                ],
                'route': {'final': 'fixture-out'},
                'experimental': {
                  'clash_api': {
                    'external_controller': '127.0.0.1:$api',
                    'secret': 'native-log-fixture',
                  },
                },
              }),
            );
        final check = await Process.run(binary!, [
          'check',
          '-c',
          configuration.path,
        ]);
        expect(check.exitCode, 0);
        for (final listener in reserved) {
          await listener.close();
        }
        process = await Process.start(binary, [
          'run',
          '-c',
          configuration.path,
          if (controlled) '--stdio-control',
        ]);
        final host = SingBoxHostEvents(process.pid);
        process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((line) {
              if (controlled) host.add(line);
            });
        unawaited(process.stderr.drain<void>());
        if (controlled) await host.ready.timeout(const Duration(seconds: 10));
        var ready = false;
        for (var i = 0; i < 60; i++) {
          try {
            final socket = await Socket.connect(
              InternetAddress.loopbackIPv4,
              api,
            );
            socket.destroy();
            ready = true;
            break;
          } on SocketException {
            await Future<void>.delayed(const Duration(milliseconds: 25));
          }
        }
        expect(ready, isTrue);
        native = SingBoxClashApiAdapter(
          endpoint: Uri.parse('http://127.0.0.1:$api'),
          secret: 'native-log-fixture',
        );
        final entries = <CoreLogMessage>[];
        final errors = <Object>[];
        logs = native.logs().listen(entries.add, onError: errors.add);
        client.findProxy = (_) => 'PROXY 127.0.0.1:$mixed';
        Future<void> forward() async {
          final request = await client.getUrl(
            Uri.parse('http://127.0.0.1:${origin.port}/native-log'),
          );
          final response = await request.close();
          expect(
            await utf8.decoder.bind(response).join(),
            'native-log-receipt',
          );
        }

        bool observed() => entries.any(
          (entry) =>
              entry.payload.contains('fixture-out') &&
              entry.payload.contains('127.0.0.1:${origin.port}'),
        );
        for (var i = 0; i < 40 && !observed(); i++) {
          await forward();
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
        expect(errors, isEmpty);
        expect(receipts, greaterThan(0));
        expect(observed(), isTrue);
        await logs.cancel().timeout(const Duration(seconds: 2));
        final count = entries.length;
        final before = receipts;
        await forward();
        expect(receipts, before + 1);
        expect(entries, hasLength(count));
      } finally {
        await logs?.cancel();
        await native?.close();
        client.close(force: true);
        final child = process;
        if (child != null) {
          if (controlled) {
            child.stdin.writeln('stop');
            await child.stdin.flush();
          } else {
            child.kill();
          }
          try {
            await child.exitCode.timeout(const Duration(seconds: 5));
          } on TimeoutException {
            child.kill(ProcessSignal.sigkill);
            await child.exitCode;
          }
        }
        for (final listener in reserved) {
          await listener.close();
        }
        await origin.close(force: true);
        await directory.delete(recursive: true);
      }
    },
    skip: binary == null ? 'Set HOTARU_TEST_SING_BOX for native logs' : false,
  );
}
