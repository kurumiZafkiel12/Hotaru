import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/config/clash_importer.dart';
import 'package:hotaru/core/config/clash_subscription.dart';
import 'package:hotaru/core/config/geodata.dart';
import 'package:hotaru/core/config/profile.dart';
import 'package:hotaru/core/config/route_preview.dart';
import 'package:hotaru/core/sing_box/config_builder.dart';
import 'package:hotaru/core/sing_box/host_events.dart';

import 'loopback_proxy_fixture.dart';
import 'support/dns_fixture.dart';
import 'support/geodata_fixture.dart';

void main() {
  final binary = Platform.environment['HOTARU_TEST_SING_BOX'];
  final controlled = Platform.environment['HOTARU_TEST_SING_BOX_HOST'] == '1';
  for (final (withGeo, noResolve, invertIp, emptySite, withProviders) in const [
    (false, false, false, false, false),
    (false, true, false, false, false),
    (true, false, false, false, false),
    (true, true, false, false, false),
    (true, true, true, false, false),
    (true, true, false, true, false),
    (false, false, false, false, true),
    (true, true, false, false, true),
    (true, false, false, false, true),
  ]) {
    test(
      'real engine IP rule geodata=$withGeo no-resolve=$noResolve inverse=$invertIp empty=$emptySite providers=$withProviders verifies DNS intent and preceding domain priority',
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
              allowedHosts: [
                '127.0.0.1',
                'prior.invalid',
                'routed.invalid',
                '192.0.2.100',
              ],
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
          final inputRules = [
            withGeo
                ? 'GEOSITE,${emptySite ? '!empty' : 'prior'},node-1'
                : 'DOMAIN,prior.invalid,node-1',
            '${withGeo ? 'GEOIP,${invertIp ? '!' : ''}local' : 'IP-CIDR,127.0.0.0/8'},node-0${noResolve ? ',no-resolve' : ''}',
            withGeo ? 'GEOSITE,routed,node-1' : 'DOMAIN,routed.invalid,node-1',
            'MATCH,node-1',
          ];
          final members = inputRules
              .take(3)
              .map((rule) => rule.split(','))
              .toList();
          Future<CoreConfigImportResult> import(
            String source, {
            CoreGeoResolver? resolveGeo,
          }) => withProviders
              ? ClashSubscriptionImporter(
                  resolve: (_) async => throw StateError('Inline only'),
                  resolveGeo: resolveGeo,
                ).import(source)
              : ClashProfileImporter().import(source, resolveGeo: resolveGeo);
          final imported = await import(
            jsonEncode({
              if (withGeo) 'geodata-mode': true,
              'dns': {
                'enable': true,
                'nameserver': ['udp://127.0.0.1:${dns.port}'],
                'use-hosts': false,
                'use-system-hosts': false,
              },
              'proxies': [
                for (var i = 0; i < proxies.length; i++)
                  {
                    'name': 'node-$i',
                    'type': 'http',
                    'server': '127.0.0.1',
                    'port': proxies[i].server.port,
                  },
              ],
              if (withProviders)
                'rule-providers': {
                  for (var i = 0; i < members.length; i++)
                    'rules-$i': {
                      'type': 'inline',
                      'behavior': 'classical',
                      'payload': ['${members[i][0]},${members[i][1]}'],
                    },
                },
              'rules': withProviders
                  ? [
                      for (var i = 0; i < members.length; i++)
                        'RULE-SET,rules-$i,${members[i][2]}${members[i].length == 4 ? ',no-resolve' : ''}',
                      'MATCH,node-1',
                    ]
                  : inputRules,
            }),
            resolveGeo: withGeo
                ? (requests) async {
                    final result = <String, CoreGeoMatchData>{};
                    for (final kind in CoreGeoKind.values) {
                      final bytes = kind == CoreGeoKind.ip
                          ? geoDatabase('LOCAL', [
                              geoPrefix([127, 0, 0, 0], 8),
                            ])
                          : Uint8List.fromList([
                              ...geoDatabase('EMPTY', []),
                              ...geoDatabase('PRIOR', [
                                geoDomain(3, 'prior.invalid'),
                              ]),
                              ...geoDatabase('ROUTED', [
                                geoDomain(2, 'routed.invalid'),
                              ]),
                            ]);
                      result.addAll(
                        await CoreGeoDecoder.decode(
                          bytes: bytes,
                          requests: requests
                              .where((request) => request.kind == kind)
                              .toList(),
                        ),
                      );
                    }
                    return result;
                  }
                : null,
          );
          expect(
            imported.issues.map((issue) => issue.code),
            noResolve ? isEmpty : ['ip_resolution_semantics_changed'],
          );
          final profile = imported.profile!;
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
          expect(
            proxies[0].receipts,
            hasLength(
              invertIp
                  ? 0
                  : noResolve
                  ? 1
                  : 2,
            ),
          );
          expect(
            proxies[1].receipts,
            hasLength(
              invertIp
                  ? 3
                  : noResolve
                  ? 2
                  : 1,
            ),
          );
          expect(originReceipts, 3);
          if (invertIp) {
            await payload('192.0.2.100');
            expect(queries, 0);
            expect(proxies[0].receipts, hasLength(1));
            expect(proxies[1].receipts, hasLength(3));
            expect(originReceipts, 4);
          }
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
