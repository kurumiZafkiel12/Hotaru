import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/adapter.dart';
import 'package:hotaru/core/config/profile.dart';
import 'package:hotaru/core/config/probe_listener.dart';
import 'package:hotaru/core/sing_box/clash_api_adapter.dart';
import 'package:hotaru/core/sing_box/config_builder.dart';
import 'package:hotaru/core/sing_box/outbound_http.dart';

import 'loopback_proxy_fixture.dart';

const _secret = 'fixture-only-not-a-production-key_123456789';

CoreProfileSpec _profile(int first, int second) => CoreProfileSpec(
  nodes: [
    CoreNodeSpec(
      tag: '日本 / A',
      protocol: CoreNodeProtocol.http,
      server: '127.0.0.1',
      port: first,
    ),
    CoreNodeSpec(
      tag: 'B',
      protocol: CoreNodeProtocol.http,
      server: '127.0.0.1',
      port: second,
    ),
  ],
  selectors: [
    CoreSelectorSpec(tag: 'selected', members: ['日本 / A', 'B'], selected: 'B'),
  ],
  finalOutbound: 'selected',
  rules: const [
    CoreRouteRule(kind: CoreRuleKind.always, value: '', outbound: 'selected'),
  ],
);

void main() {
  test(
    'probe listener is optional, loopback, authenticated, and ahead of final rules',
    () async {
      final builder = SingBoxConfigBuilder();
      final built = await builder.build(
        _profile(8080, 8081),
        const CoreListenerSpec(
          mixedPort: 17890,
          controllerPort: 19090,
          secret: 'controller',
          probe: CoreProbeListenerSpec(port: 17891, secret: _secret),
        ),
      );
      expect(built.issues, isEmpty);
      final config = jsonDecode(built.json!);
      final probe = config['inbounds'].first;
      expect(probe['listen'], '127.0.0.1');
      expect(probe['type'], 'http');
      expect(probe['users'], hasLength(3));
      expect(
        probe['users'].first['username'],
        CoreProbeListenerSpec.username('日本 / A'),
      );
      final rules = config['route']['rules'] as List;
      expect(rules.first['inbound'], ['hotaru-probe']);
      expect(rules.first['outbound'], '日本 / A');
      expect(rules[3], {
        'inbound': ['hotaru-probe'],
        'action': 'reject',
      });
      expect(rules.last['outbound'], 'selected');
      for (final port in [0, 65536, 17890, 19090]) {
        final invalid = await builder.build(
          _profile(8080, 8081),
          CoreListenerSpec(
            mixedPort: 17890,
            controllerPort: 19090,
            secret: 'controller',
            probe: CoreProbeListenerSpec(port: port, secret: _secret),
          ),
        );
        expect(invalid.json, isNull);
        expect(invalid.issues.single.code, 'invalid_probe_listener');
      }
      final invalid = await builder.build(
        _profile(8080, 8081),
        const CoreListenerSpec(
          mixedPort: 17890,
          controllerPort: 19090,
          secret: 'controller',
          probe: CoreProbeListenerSpec(port: 17891, secret: 'weak'),
        ),
      );
      expect(invalid.json, isNull);
    },
  );

  test(
    'missing capability, unknown node, bad timeout and closed session do not run callbacks',
    () async {
      var calls = 0;
      Future<void> action(HttpClient _) async {
        calls++;
      }

      final missing = SingBoxOutboundHttp(listener: null, outbounds: []);
      await expectLater(
        missing.withOutboundClient('A', action),
        throwsA(
          isA<CoreAdapterException>().having(
            (e) => e.code,
            'code',
            'outbound_http_unavailable',
          ),
        ),
      );
      final present = SingBoxOutboundHttp(
        listener: const CoreProbeListenerSpec(port: 17891, secret: _secret),
        outbounds: ['A'],
      );
      await expectLater(
        present.withOutboundClient('missing', action),
        throwsA(
          isA<CoreAdapterException>().having(
            (e) => e.code,
            'code',
            'unknown_outbound',
          ),
        ),
      );
      await expectLater(
        present.withOutboundClient('A', action, timeout: Duration.zero),
        throwsArgumentError,
      );
      present.close();
      await expectLater(
        present.withOutboundClient('A', action),
        throwsA(
          isA<CoreAdapterException>().having((e) => e.code, 'code', 'closed'),
        ),
      );
      expect(calls, 0);
    },
  );

  test(
    'callback timeout closes its client without closing other callbacks',
    () async {
      final transport = SingBoxOutboundHttp(
        listener: const CoreProbeListenerSpec(port: 17891, secret: _secret),
        outbounds: ['A'],
      );
      addTearDown(transport.close);
      final completed = Completer<void>();
      HttpClient? client;
      await expectLater(
        transport.withOutboundClient('A', (current) {
          client = current;
          return completed.future;
        }, timeout: const Duration(milliseconds: 20)),
        throwsA(
          isA<CoreAdapterException>().having((e) => e.code, 'code', 'timeout'),
        ),
      );
      expect(
        () => client!.getUrl(Uri.parse('http://127.0.0.1/')),
        throwsStateError,
      );
      completed.complete();
      expect(await transport.withOutboundClient('A', (_) async => 42), 42);
    },
  );

  final binary = Platform.environment['HOTARU_TEST_SING_BOX'];
  final controlled = Platform.environment['HOTARU_TEST_SING_BOX_HOST'] == '1';
  test(
    'real engine binds simultaneous HTTP and HTTPS probes to clicked nodes without changing selection',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'hotaru-node-probe-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final tls = SecurityContext()
        ..useCertificateChain('test/core/sing_box/support/tls/cert.pem')
        ..usePrivateKey('test/core/sing_box/support/tls/key.pem');
      final secureOrigin = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        tls,
      );
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => secureOrigin.close(force: true));
      addTearDown(() => origin.close(force: true));
      final receipts = <String>[];
      void respond(HttpRequest request) {
        receipts.add(request.uri.path);
        expect(
          request.headers.value(HttpHeaders.proxyAuthorizationHeader),
          isNull,
        );
        request.response.write('node-proof');
        unawaited(request.response.close());
      }

      secureOrigin.listen(respond);
      origin.listen(respond);
      final first = LoopbackProxyFixture(
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
        origin.port,
      );
      final second = LoopbackProxyFixture(
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
        secureOrigin.port,
      );
      addTearDown(first.close);
      addTearDown(second.close);
      final mixed = await freeLoopbackPort();
      final controller = await freeLoopbackPort();
      final probe = CoreProbeListenerSpec(
        port: await freeLoopbackPort(),
        secret: _secret,
      );
      final built = await SingBoxConfigBuilder().build(
        _profile(first.server.port, second.server.port),
        CoreListenerSpec(
          mixedPort: mixed,
          controllerPort: controller,
          secret: 'controller',
          probe: probe,
        ),
      );
      expect(built.issues, isEmpty);
      final file = await File(
        '${directory.path}/config.json',
      ).writeAsString(built.json!);
      final process = await Process.start(binary!, [
        'run',
        '-c',
        file.path,
        if (controlled) '--stdio-control',
      ]);
      var exited = false;
      final exitCode = process.exitCode.then((code) {
        exited = true;
        return code;
      });
      final output = <String>[];
      final readers = [
        process.stdout.transform(utf8.decoder).forEach(output.add),
        process.stderr.transform(utf8.decoder).forEach(output.add),
      ];
      final adapter = SingBoxClashApiAdapter(
        endpoint: Uri.parse('http://127.0.0.1:$controller'),
        secret: 'controller',
        probe: probe,
        probeOutbounds: ['日本 / A', 'B', 'selected'],
      );
      try {
        var ready = false;
        for (var attempt = 0; attempt < 100; attempt++) {
          try {
            await adapter.version();
            ready = true;
            break;
          } catch (_) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        }
        expect(ready, isTrue, reason: output.join());
        final fixtureCertificate = await File(
          'test/core/sing_box/support/tls/cert.pem',
        ).readAsString();
        Future<String> fetch(String node, Uri target) =>
            adapter.withOutboundClient(node, (client) async {
              client.badCertificateCallback = (certificate, host, port) =>
                  host == '127.0.0.1' &&
                  port == secureOrigin.port &&
                  certificate.pem.trim() == fixtureCertificate.trim();
              final request = await client.getUrl(target);
              final response = await request.close();
              expect(response.statusCode, 200);
              return utf8.decoder.bind(response).join();
            });
        final results = await Future.wait([
          fetch('日本 / A', Uri.parse('http://127.0.0.1:${origin.port}/first')),
          fetch(
            'B',
            Uri.parse('https://127.0.0.1:${secureOrigin.port}/second'),
          ),
        ]).timeout(const Duration(seconds: 10));
        expect(results, ['node-proof', 'node-proof']);
        expect(first.receipts, [origin.port]);
        expect(second.receipts, [secureOrigin.port]);
        expect(receipts.toSet(), {'/first', '/second'});
        expect(
          (await adapter.outbounds())
              .singleWhere((o) => o.name == 'selected')
              .selected,
          'B',
        );
        final unauthenticated = await Socket.connect(
          InternetAddress.loopbackIPv4,
          probe.port,
        );
        final unauthorizedResponse = Completer<String>();
        final unauthorizedBytes = <int>[];
        final unauthorizedSubscription = unauthenticated.listen(
          (bytes) {
            unauthorizedBytes.addAll(bytes);
            final text = utf8.decode(unauthorizedBytes);
            if (text.contains('\r\n\r\n') &&
                !unauthorizedResponse.isCompleted) {
              unauthorizedResponse.complete(text);
            }
          },
          onError: (Object error, StackTrace trace) {
            if (!unauthorizedResponse.isCompleted) {
              if (error is SocketException &&
                  [104, 10054].contains(error.osError?.errorCode)) {
                unauthorizedResponse.complete('reset');
              } else {
                unauthorizedResponse.completeError(error, trace);
              }
            }
          },
          onDone: () {
            if (!unauthorizedResponse.isCompleted) {
              unauthorizedResponse.complete(utf8.decode(unauthorizedBytes));
            }
          },
        );
        try {
          final rejected = expectLater(
            unauthorizedResponse.future.timeout(const Duration(seconds: 5)),
            completion(anyOf(startsWith('HTTP/1.1 407'), 'reset')),
          );
          unauthenticated.write(
            'GET http://127.0.0.1:${origin.port}/forbidden HTTP/1.1\r\nHost: 127.0.0.1:${origin.port}\r\nConnection: close\r\n\r\n',
          );
          await unauthenticated.flush();
          await rejected;
        } finally {
          await unauthorizedSubscription.cancel();
          unauthenticated.destroy();
        }
        expect(receipts, hasLength(2));
        expect(await adapter.version(), 'sing-box 1.14.4');
        stdout.writeln(
          jsonEncode({
            'scope': 'Owned loopback proxies only; no OS proxy or TUN',
            'controlled_host': controlled,
            'http_node_receipts': first.receipts,
            'https_node_receipts': second.receipts,
            'selected_unchanged': 'B',
            'unauthenticated_origin_requests': 0,
          }),
        );
      } finally {
        await adapter.close();
        try {
          if (controlled) {
            process.stdin.writeln('stop');
            await process.stdin.flush();
            await process.stdin.close();
          } else {
            process.kill(ProcessSignal.sigterm);
          }
          final code = await exitCode.timeout(const Duration(seconds: 5));
          await Future.wait(readers);
          if (controlled) {
            expect(code, 0);
            expect(output.join(), contains('"clean":true'));
          }
        } finally {
          if (!exited) {
            process.kill(ProcessSignal.sigterm);
            await exitCode.timeout(const Duration(seconds: 5));
          }
        }
      }
    },
    skip: binary == null
        ? 'Set HOTARU_TEST_SING_BOX to verified pinned engine'
        : false,
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
