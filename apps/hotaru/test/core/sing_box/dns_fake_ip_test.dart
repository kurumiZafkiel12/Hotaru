import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/config/clash_dns.dart';
import 'package:hotaru/core/config/clash_importer.dart';
import 'package:hotaru/core/config/dns.dart';
import 'package:hotaru/core/config/dns_domain_filter.dart';
import 'package:hotaru/core/config/geodata.dart';
import 'package:hotaru/core/config/ip_prefix.dart';
import 'package:hotaru/core/config/profile.dart';
import 'package:hotaru/core/config/rule_set.dart';
import 'package:hotaru/core/sing_box/config_builder.dart';
import 'package:hotaru/core/sing_box/host_events.dart';

import 'loopback_proxy_fixture.dart';
import 'support/dns_fixture.dart';
import 'support/geodata_fixture.dart';

Map<String, Object?> _settings() => {
  'enable': true,
  'enhanced-mode': 'fake-ip',
  'nameserver': ['192.0.2.1'],
  'use-hosts': false,
  'use-system-hosts': false,
};

void main() {
  test(
    'domain filters preserve single-label and suffix wildcard boundaries',
    () {
      for (final entry in <String, Map<String, bool>>{
        'EXAMPLE.invalid': {
          'example.invalid': true,
          'a.example.invalid': false,
        },
        '*.example.invalid': {
          'example.invalid': false,
          'a.example.invalid': true,
          'a.b.example.invalid': false,
        },
        '+.example.invalid': {
          'example.invalid': true,
          'a.b.example.invalid': true,
          'other.invalid': false,
        },
        '.example.invalid': {
          'example.invalid': false,
          'a.b.example.invalid': true,
        },
        'a.*.invalid': {'a.x.invalid': true, 'a.x.y.invalid': false},
      }.entries) {
        final filter = readDnsDomainFilter(entry.key, {}).single.set;
        for (final match in entry.value.entries) {
          final matches =
              filter.domains.contains(match.key) ||
              filter.regexes.any((regex) => RegExp(regex).hasMatch(match.key));
          expect(matches, match.value, reason: '${entry.key} / ${match.key}');
        }
      }
      for (final pattern in [
        '',
        '+',
        '*a.invalid',
        'a..invalid',
        'a.invalid.',
        'a.+.invalid',
        ' rule.invalid',
        'rule-set:external',
      ]) {
        expect(() => readDnsDomainFilter(pattern, {}), throwsFormatException);
      }
    },
  );

  test(
    'fake-IP settings are typed, bounded and never silently approximated',
    () async {
      final imported = importClashDns(_settings());
      expect(imported.issues, isEmpty);
      final fake = imported.dns!.fakeIp!;
      expect(fake.ipv4Range, '198.18.0.1/16');
      expect(fake.ipv6Range, isNull);
      expect(fake.ttl, 1);
      expect(fake.filters.map((filter) => filter.set.domains.single), [
        'dns.msftnsci.com',
        'www.msftnsci.com',
        'www.msftconnecttest.com',
      ]);
      for (final extra in <Map<String, Object?>>[
        {'fake-ip-range': '2001:db8::/64'},
        {'fake-ip-range': '198.18.0.1/32'},
        {'fake-ip-range': '', 'fake-ip-range6': ''},
        {'fake-ip-range6': '192.0.2.0/24'},
        {'fake-ip-ttl': -1},
        {'fake-ip-ttl': 0x100000000},
        {
          'fake-ip-filter': ['geosite:missing'],
        },
        {
          'fake-ip-filter': ['rule-set:missing'],
        },
        {
          'fake-ip-filter': ['x..invalid'],
        },
        {'fake-ip-filter-mode': 'rule'},
        {'fake-ip-filter-mode': 'unknown'},
      ]) {
        final result = importClashDns({..._settings(), ...extra});
        expect(result.dns, isNull, reason: '$extra');
        expect(result.issues, isNotEmpty);
      }
      final inactive = importClashDns({
        ..._settings(),
        'enhanced-mode': 'redir-host',
        'fake-ip-filter': [],
      });
      expect(inactive.dns!.fakeIp, isNull);
      expect(inactive.issues.single.code, 'inactive_dns_fake_ip_settings');
      for (final mode in CoreDnsFilterMode.values) {
        final empty = importClashDns({
          ..._settings(),
          'fake-ip-filter': [],
          'fake-ip-filter-mode': mode.name,
        });
        final built = await SingBoxConfigBuilder().build(
          CoreProfileSpec(
            nodes: const [
              CoreNodeSpec(tag: 'DIRECT', protocol: CoreNodeProtocol.direct),
            ],
            selectors: [],
            finalOutbound: 'DIRECT',
            dns: empty.dns,
          ),
          const CoreListenerSpec(
            mixedPort: 17890,
            controllerPort: 19090,
            secret: 'fixture',
          ),
        );
        expect(built.issues, isEmpty);
        final rules = jsonDecode(built.json!)['dns']['rules'] as List;
        expect(rules.length, mode == CoreDnsFilterMode.blacklist ? 3 : 1);
        expect(rules.last['query_type'], [28]);
      }
      final bad = CoreDnsSpec(
        servers: imported.dns!.servers,
        finalServer: imported.dns!.finalServer,
        fakeIp: CoreDnsFakeIpSpec(
          ipv4Range: '192.0.2.1/32',
          ttl: -1,
          filters: [
            CoreDnsDomainFilter(
              CoreRuleSetSpec(
                tag: 'bad',
                kind: CoreRuleSetKind.ipCidr,
                prefixes: ['not-an-ip'],
              ),
            ),
          ],
        ),
      );
      final built = await SingBoxConfigBuilder().build(
        CoreProfileSpec(
          nodes: const [
            CoreNodeSpec(tag: 'DIRECT', protocol: CoreNodeProtocol.direct),
          ],
          selectors: [],
          finalOutbound: 'DIRECT',
          dns: bad,
        ),
        const CoreListenerSpec(
          mixedPort: 17890,
          controllerPort: 19090,
          secret: 'fixture',
        ),
      );
      expect(built.json, isNull);
      expect(
        built.issues.map((issue) => issue.code),
        containsAll([
          'invalid_fake_ip_range',
          'invalid_fake_ip_ttl',
          'invalid_dns_filter_kind',
          'invalid_rule_set_matcher',
        ]),
      );
    },
  );

  test(
    'DNS-only GeoSite filters resolve through the authorized callback',
    () async {
      final seen = <String>[];
      final imported = await ClashProfileImporter().importDocument(
        {
          'dns': {
            ..._settings(),
            'fake-ip-filter': ['geosite:xx,!xx'],
          },
          'rules': ['MATCH,DIRECT'],
        },
        resolveGeo: (requests) async {
          seen.addAll(requests.map((request) => request.key));
          return CoreGeoDecoder.decode(
            bytes: geoDatabase('XX', [geoDomain(2, 'example.invalid')]),
            requests: requests,
          );
        },
      );
      expect(imported.issues, isEmpty);
      expect(seen, ['site:xx', 'site:!xx']);
      expect(imported.profile!.dns!.fakeIp!.filters.map((f) => f.invert), [
        false,
        true,
      ]);
      expect(imported.profile!.ruleSets, isEmpty);
    },
  );

  final binary = Platform.environment['HOTARU_TEST_SING_BOX'];
  final controlled = Platform.environment['HOTARU_TEST_SING_BOX_HOST'] == '1';
  for (final (mode, range6) in const [
    (CoreDnsFilterMode.blacklist, true),
    (CoreDnsFilterMode.whitelist, true),
    (CoreDnsFilterMode.blacklist, false),
    (CoreDnsFilterMode.whitelist, false),
  ]) {
    test(
      'real ${mode.name} range6=$range6 fake-IP replies, filters, endpoint DNS and restored domain forwarding',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'hotaru-fakeip-',
        );
        final upstream = await RawDatagramSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final proxy = LoopbackProxyFixture(
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
          origin.port,
          allowedHosts: const ['fake-fixture.invalid'],
        );
        final receipts = <String>[];
        var originReceipts = 0;
        origin.listen((request) async {
          originReceipts++;
          request.response.write('restored-domain-receipt');
          await request.response.close();
        });
        upstream.listen((event) {
          if (event != RawSocketEvent.read) return;
          final packet = upstream.receive();
          if (packet == null) return;
          var offset = 12;
          final labels = <String>[];
          while (packet.data[offset] != 0) {
            final length = packet.data[offset++];
            labels.add(
              ascii.decode(packet.data.sublist(offset, offset + length)),
            );
            offset += length;
          }
          final host = labels.join('.');
          receipts.add(host);
          final response = answer(packet.data);
          if (host == 'proxy-fixture.invalid') {
            response.setRange(response.length - 4, response.length, [
              127,
              0,
              0,
              1,
            ]);
          }
          upstream.send(response, packet.address, packet.port);
        });
        final reserved = <ServerSocket>[];
        final client = HttpClient();
        Process? process;
        final output = <String>[];
        try {
          Future<int> port() async {
            final server = await ServerSocket.bind(
              InternetAddress.loopbackIPv4,
              0,
            );
            reserved.add(server);
            return server.port;
          }

          final dnsPort = await port();
          final mixed = await port();
          final api = await port();
          final groupPort = await port();
          final address = 'udp://127.0.0.1:${upstream.port}';
          final imported = importClashDns(
            {
              ..._settings(),
              'ipv6': false,
              'nameserver': [address, address],
              'proxy-server-nameserver': [address],
              if (range6) 'fake-ip-range6': 'fd00:1234::/64',
              'fake-ip-ttl': 7,
              'fake-ip-filter-mode': mode.name,
              'fake-ip-filter': mode == CoreDnsFilterMode.blacklist
                  ? ['geosite:real,empty', '*.one.invalid']
                  : ['+.fake.invalid', 'fake-fixture.invalid', 'geosite:empty'],
            },
            geodata: {
              'site:real': CoreGeoMatchData(
                CoreRuleSetSpec(
                  tag: 'real',
                  kind: CoreRuleSetKind.domain,
                  suffixes: ['real.invalid'],
                ),
                false,
              ),
              'site:empty': CoreGeoMatchData(
                CoreRuleSetSpec(tag: 'empty', kind: CoreRuleSetKind.domain),
                false,
              ),
            },
          );
          expect(imported.issues, isEmpty);
          final built = await SingBoxConfigBuilder().build(
            CoreProfileSpec(
              nodes: [
                CoreNodeSpec(
                  tag: 'proxy',
                  protocol: CoreNodeProtocol.http,
                  server: 'proxy-fixture.invalid',
                  port: proxy.server.port,
                ),
              ],
              selectors: [],
              finalOutbound: 'proxy',
              dns: imported.dns,
            ),
            CoreListenerSpec(
              mixedPort: mixed,
              controllerPort: api,
              secret: 'fixture',
              dnsPort: dnsPort,
              dnsGroups: CoreDnsGroupListeners({'dns-main': groupPort}),
            ),
          );
          expect(
            built.issues,
            isEmpty,
            reason: built.issues.map((i) => i.code).join(','),
          );
          final config = await File(
            '${directory.path}/config.json',
          ).writeAsString(built.json!);
          final check = await Process.run(binary!, [
            'check',
            '-c',
            config.path,
          ]);
          expect(check.exitCode, 0, reason: '${check.stderr}');
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
                dnsPort,
              );
              socket.destroy();
              ready = true;
              break;
            } on SocketException {
              await Future<void>.delayed(const Duration(milliseconds: 50));
            }
          }
          expect(ready, isTrue, reason: output.join());
          final fake = await udpQuery(
            dnsPort,
            question('fake-fixture.invalid'),
          );
          expect(fake[3] & 15, 0, reason: output.join());
          final fakeAddress = InternetAddress.fromRawAddress(
            Uint8List.fromList(fake.sublist(fake.length - 4)),
          );
          expect(
            CoreIpPrefix.parse('198.18.0.0/16')!.contains(fakeAddress),
            isTrue,
          );
          expect(fake.sublist(fake.length - 10, fake.length - 6), [0, 0, 0, 7]);
          expect(
            receipts,
            isEmpty,
            reason: 'fake replies must not consult upstream',
          );
          final ipv6 = await udpQuery(
            dnsPort,
            question('a.fake.invalid', type: 28),
          );
          if (range6) {
            expect(ipv6.sublist(ipv6.length - 16).take(4), [
              0xfd,
              0,
              0x12,
              0x34,
            ]);
          } else {
            expect(ipv6.sublist(6, 8), [0, 0]);
          }
          for (final type in [64, 65]) {
            final empty = await udpQuery(
              dnsPort,
              question('a.fake.invalid', type: type),
            );
            expect(empty[3] & 15, 0);
            expect(empty.sublist(6, 8), [0, 0]);
          }
          expect(receipts, isEmpty);
          final realV6 = await udpQuery(
            dnsPort,
            question('a.real.invalid', type: 28),
          );
          expect(realV6.sublist(6, 8), [0, 0]);
          expect(receipts, isEmpty);
          for (final domain in [
            'real.invalid',
            'a.real.invalid',
            'a.one.invalid',
          ]) {
            final response = await udpQuery(dnsPort, question(domain));
            expect(response.sublist(response.length - 4), [192, 0, 2, 45]);
            expect(receipts, contains(domain));
          }
          if (mode == CoreDnsFilterMode.blacklist) {
            final deep = await udpQuery(dnsPort, question('a.b.one.invalid'));
            expect(deep.sublist(deep.length - 4).take(2), [198, 18]);
            expect(receipts, isNot(contains('a.b.one.invalid')));
          }
          await udpQuery(dnsPort, question('txt.fake.invalid', type: 16));
          expect(receipts, contains('txt.fake.invalid'));
          client.findProxy = (_) => 'PROXY 127.0.0.1:$mixed';
          final request = await client
              .getUrl(
                Uri.parse(
                  'http://${fakeAddress.address}:${origin.port}/receipt',
                ),
              )
              .catchError((Object error, StackTrace stack) {
                Error.throwWithStackTrace(
                  StateError('$error\nOwned core output:\n${output.join()}'),
                  stack,
                );
              });
          final response = await request.close();
          expect(response.statusCode, 200, reason: output.join());
          expect(
            await response.transform(utf8.decoder).join(),
            'restored-domain-receipt',
          );
          expect(originReceipts, 1);
          expect(proxy.receipts, [origin.port]);
          expect(
            receipts,
            contains('proxy-fixture.invalid'),
            reason: 'internal endpoint lookup must bypass fake-IP',
          );
          expect(receipts, isNot(contains('fake-fixture.invalid')));
        } finally {
          client.close(force: true);
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
          upstream.close();
          await proxy.close();
          await origin.close(force: true);
          for (final server in reserved) {
            await server.close();
          }
          await directory.delete(recursive: true);
        }
      },
      skip: binary == null
          ? 'Set HOTARU_TEST_SING_BOX for real fake-IP receipts'
          : false,
    );
  }
}
