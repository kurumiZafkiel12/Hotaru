import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/config/clash_dns.dart';
import 'package:hotaru/core/config/profile.dart';
import 'package:hotaru/core/config/route_preview.dart';
import 'package:hotaru/core/sing_box/config_builder.dart';
import 'package:hotaru/core/sing_box/host_events.dart';

import 'loopback_proxy_fixture.dart';
import 'support/dns_fixture.dart';

void main() {
  final binary = Platform.environment['HOTARU_TEST_SING_BOX'];
  final controlled = Platform.environment['HOTARU_TEST_SING_BOX_HOST'] == '1';
  for (final noResolve in [false, true]) {
    test(
      'real engine IP rule no-resolve=$noResolve verifies DNS intent and preceding domain priority',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'hotaru-ip-resolution-',
        );
        final dns = await RawDatagramSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        var queries = 0;
        var multipleAnswers = false;
        var lookupFailure = false;
        dns.listen((event) {
          if (event != RawSocketEvent.read) return;
          final packet = dns.receive();
          if (packet == null) return;
          queries++;
          final response = answer(packet.data);
          response.setRange(response.length - 4, response.length, [
            127,
            0,
            0,
            1,
          ]);
          if (lookupFailure) {
            response[3] = 0x83;
            response[7] = 0;
            response.removeRange(response.length - 16, response.length);
          } else if (multipleAnswers) {
            final second = response.sublist(response.length - 16);
            response.setRange(response.length - 4, response.length, [
              192,
              0,
              2,
              100,
            ]);
            response[7] = 2;
            response.addAll(second);
          }
          dns.send(response, packet.address, packet.port);
        });
        final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        var originReceipts = 0;
        origin.listen((request) async {
          originReceipts++;
          request.response.write('receipt:${request.uri.path}');
          await request.response.close();
        });
        final proxies = [
          for (var i = 0; i < 2; i++)
            LoopbackProxyFixture(
              await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
              origin.port,
              allowedHosts: ['127.0.0.1', 'prior.invalid', 'routed.invalid'],
            ),
        ];
        final reserved = <ServerSocket>[];
        Process? process;
        final output = <String>[];
        try {
          Future<int> reserve() async {
            final server = await ServerSocket.bind(
              InternetAddress.loopbackIPv4,
              0,
            );
            reserved.add(server);
            return server.port;
          }

          final mixed = await reserve();
          final controller = await reserve();
          final imported = importClashDns({
            'enable': true,
            'nameserver': ['udp://127.0.0.1:${dns.port}'],
            'use-hosts': false,
            'use-system-hosts': false,
          });
          final profile = CoreProfileSpec(
            nodes: [
              for (var i = 0; i < proxies.length; i++)
                CoreNodeSpec(
                  tag: 'node-$i',
                  protocol: CoreNodeProtocol.http,
                  server: '127.0.0.1',
                  port: proxies[i].server.port,
                ),
            ],
            selectors: [],
            finalOutbound: 'node-1',
            dns: imported.dns,
            rules: [
              const CoreRouteRule(
                kind: CoreRuleKind.domain,
                value: 'prior.invalid',
                outbound: 'node-1',
              ),
              CoreRouteRule(
                kind: CoreRuleKind.ipCidr,
                value: '127.0.0.0/8',
                outbound: 'node-0',
                noResolve: noResolve,
              ),
              const CoreRouteRule(
                kind: CoreRuleKind.domain,
                value: 'routed.invalid',
                outbound: 'node-1',
              ),
            ],
          );
          final preview = await CoreRoutePreviewer().preview(
            profile,
            'routed.invalid',
          );
          expect(
            preview.status,
            noResolve
                ? CoreRoutePreviewStatus.resolved
                : CoreRoutePreviewStatus.addressRequired,
          );
          expect(queries, 0);
          final built = await SingBoxConfigBuilder().build(
            profile,
            CoreListenerSpec(
              mixedPort: mixed,
              controllerPort: controller,
              secret: 'fixture',
            ),
          );
          expect(built.issues, isEmpty);
          final config = await File(
            '${directory.path}/config.json',
          ).writeAsString(built.json!);
          final checked = await Process.run(binary!, [
            'check',
            '-c',
            config.path,
          ]);
          expect(checked.exitCode, 0, reason: '${checked.stderr}');
          for (final server in reserved) {
            await server.close();
          }
          process = await Process.start(binary, [
            'run',
            '-c',
            config.path,
            if (controlled) '--stdio-control',
          ]);
          final host = SingBoxHostEvents(process.pid);
          process.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .listen((line) {
                output.add(line);
                if (controlled) host.add(line);
              });
          process.stderr.transform(utf8.decoder).listen(output.add);
          if (controlled) await host.ready.timeout(const Duration(seconds: 10));
          var ready = false;
          for (var i = 0; i < 60; i++) {
            try {
              final socket = await Socket.connect(
                InternetAddress.loopbackIPv4,
                mixed,
              );
              socket.destroy();
              ready = true;
              break;
            } on SocketException {
              await Future<void>.delayed(const Duration(milliseconds: 50));
            }
          }
          expect(ready, isTrue, reason: output.join());
          Future<void> payload(String host, {bool success = true}) async {
            final client = HttpClient()
              ..connectionTimeout = const Duration(seconds: 3)
              ..findProxy = (_) => 'PROXY 127.0.0.1:$mixed';
            try {
              final request = await client
                  .getUrl(Uri.parse('http://$host:${origin.port}/$host'))
                  .timeout(const Duration(seconds: 3));
              final response = await request.close().timeout(
                const Duration(seconds: 3),
              );
              if (!success) {
                expect(
                  response.statusCode,
                  inInclusiveRange(400, 599),
                  reason: output.join(),
                );
                await response.drain<void>().timeout(
                  const Duration(seconds: 3),
                );
                return;
              }
              expect(response.statusCode, 200, reason: output.join());
              expect(
                await response
                    .transform(utf8.decoder)
                    .join()
                    .timeout(const Duration(seconds: 3)),
                'receipt:/$host',
              );
            } on HttpException {
              if (success) rethrow;
            } finally {
              client.close(force: true);
            }
          }

          await payload('prior.invalid');
          expect(queries, 0);
          expect(proxies[0].receipts, isEmpty);
          expect(proxies[1].receipts, hasLength(1));
          await payload('routed.invalid');
          expect(queries, noResolve ? 0 : 1);
          expect(proxies[0].receipts, hasLength(noResolve ? 0 : 1));
          expect(proxies[1].receipts, hasLength(noResolve ? 2 : 1));
          await payload('127.0.0.1');
          expect(queries, noResolve ? 0 : 1);
          expect(proxies[0].receipts, hasLength(noResolve ? 1 : 2));
          expect(originReceipts, 3);
          if (!noResolve) {
            multipleAnswers = true;
            await payload('multi.invalid');
            expect(queries, 2);
            expect(proxies[0].receipts, hasLength(3));
            expect(proxies[1].receipts, hasLength(1));
            expect(originReceipts, 4);
            lookupFailure = true;
            await payload('missing.invalid', success: false);
            expect(queries, 3);
            expect(proxies[0].receipts, hasLength(3));
            expect(proxies[1].receipts, hasLength(1));
            expect(originReceipts, 4);
          }
        } finally {
          if (process != null) {
            if (controlled) {
              process.stdin.writeln('stop');
              await process.stdin.flush();
              await process.stdin.close();
              expect(
                await process.exitCode.timeout(const Duration(seconds: 5)),
                0,
              );
            } else {
              process.kill();
              await process.exitCode.timeout(const Duration(seconds: 5));
            }
          }
          dns.close();
          await origin.close(force: true);
          for (final proxy in proxies) {
            await proxy.close();
          }
          for (final server in reserved) {
            await server.close();
          }
          await directory.delete(recursive: true);
        }
      },
      skip: binary == null
          ? 'Set HOTARU_TEST_SING_BOX for actual DNS and node receipts'
          : false,
    );
  }
}
