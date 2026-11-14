import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/config/clash_importer.dart';
import 'package:hotaru/core/config/geodata.dart';
import 'package:hotaru/core/config/profile.dart';
import 'package:hotaru/core/config/route_preview.dart';
import 'package:hotaru/core/config/rule_set.dart';
import 'package:hotaru/core/geodata_files.dart';
import 'package:hotaru/core/sing_box/config_builder.dart';

import 'support/geodata_fixture.dart';

void main() {
  test(
    'syntax failures do not invoke geo resolution and conflicting responses cannot replace a profile',
    () async {
      var called = false;
      final syntax = await ClashProfileImporter().import(
        'rules: [',
        resolveGeo: (_) async {
          called = true;
          return {};
        },
      );
      expect(called, isFalse);
      expect(syntax.issues.single.code, 'invalid_yaml');
      final conflict = await ClashProfileImporter().import(
        'geodata-mode: true\nrules: ["GEOIP,xx,DIRECT,no-resolve", "GEOIP,yy,DIRECT,no-resolve", "MATCH,DIRECT"]',
        resolveGeo: (requests) async => {
          for (final request in requests)
            request.key: CoreGeoMatchData(
              CoreRuleSetSpec(
                tag: 'same',
                kind: CoreRuleSetKind.ipCidr,
                prefixes: [
                  request.country == 'xx' ? '192.0.2.0/24' : '198.51.100.0/24',
                ],
              ),
              false,
            ),
        },
      );
      expect(conflict.profile, isNull);
      expect(conflict.issues.single.code, 'conflicting_geo_rule_set');
    },
  );

  test(
    'LAN preserves the source address classes without widening to all reserved IPs',
    () async {
      final imported = await ClashProfileImporter().import(
        'rules: ["GEOIP,LAN,DIRECT,no-resolve", "GEOIP,LAN,DIRECT,no-resolve", "MATCH,REJECT"]',
      );
      expect(imported.issues, isEmpty);
      expect(imported.profile!.ruleSets, hasLength(1));
      final preview = CoreRoutePreviewer();
      for (final address in [
        '0.0.0.0',
        '10.0.0.1',
        '127.0.0.1',
        '169.254.1.1',
        '172.16.1.1',
        '192.168.1.1',
        '224.0.0.1',
        '::',
        '::1',
        'fc00::1',
        'fe80::1',
        'ff02::1',
      ]) {
        expect(
          (await preview.preview(imported.profile!, address)).action,
          CoreRuleAction.route,
          reason: address,
        );
      }
      for (final address in [
        '0.0.0.1',
        '100.64.0.1',
        '192.0.2.1',
        '255.255.255.255',
        '2001:db8::1',
        'unresolved.invalid',
      ]) {
        expect(
          (await preview.preview(imported.profile!, address)).action,
          CoreRuleAction.reject,
          reason: address,
        );
      }
      final resolved = await const CoreGeoDataFiles().resolve([
        CoreGeoRequest.parse(CoreGeoKind.ip, 'lan')!,
      ]);
      expect(resolved.keys, ['ip:lan']);
    },
  );

  test(
    'using a dat database instead of source MMDB remains an explicit conversion warning',
    () async {
      final request = CoreGeoRequest.parse(CoreGeoKind.ip, 'xx')!;
      final data = await CoreGeoDecoder.decode(
        bytes: geoDatabase('XX', [
          geoPrefix([192, 0, 2, 0], 24),
        ]),
        requests: [request],
      );
      final imported = await ClashProfileImporter().import(
        'rules: ["GEOIP,xx,DIRECT,no-resolve", "MATCH,DIRECT"]',
        resolveGeo: (_) async => data,
      );
      expect(imported.profile, isNotNull);
      expect(imported.issues.single.code, 'geoip_database_changed');
      expect(imported.issues.single.severity, CoreConfigIssueSeverity.warning);
    },
  );

  test(
    'typed empty sets preserve resolution intent and inverted matcher context',
    () async {
      CoreProfileSpec spec(
        CoreRuleSetSpec set, {
        bool invert = false,
        bool noResolve = false,
      }) => CoreProfileSpec(
        nodes: const [
          CoreNodeSpec(tag: 'chosen', protocol: CoreNodeProtocol.direct),
          CoreNodeSpec(tag: 'fallback', protocol: CoreNodeProtocol.direct),
        ],
        selectors: [],
        finalOutbound: 'fallback',
        ruleSets: [set],
        rules: [
          CoreRouteRule(
            kind: CoreRuleKind.ruleSet,
            value: set.tag,
            outbound: 'chosen',
            noResolve: noResolve,
            invert: invert,
          ),
        ],
      );
      final domain = CoreRuleSetSpec(
        tag: 'empty',
        kind: CoreRuleSetKind.domain,
      );
      final ip = CoreRuleSetSpec(tag: 'empty', kind: CoreRuleSetKind.ipCidr);
      final preview = CoreRoutePreviewer();
      expect(
        (await preview.preview(
          spec(domain, invert: true),
          'host.invalid',
        )).chain,
        ['chosen'],
      );
      expect(
        (await preview.preview(spec(domain, invert: true), '192.0.2.1')).chain,
        ['fallback'],
      );
      expect(
        (await preview.preview(
          spec(ip, invert: true, noResolve: true),
          'host.invalid',
        )).chain,
        ['fallback'],
      );
      expect(
        (await preview.preview(
          spec(ip, invert: true, noResolve: true),
          '192.0.2.1',
        )).chain,
        ['chosen'],
      );
      expect(
        (await preview.preview(spec(ip), 'host.invalid')).status,
        CoreRoutePreviewStatus.addressRequired,
      );
      final builder = SingBoxConfigBuilder();
      const listeners = CoreListenerSpec(
        mixedPort: 17890,
        controllerPort: 19090,
        secret: 'fixture',
      );
      final built = await builder.build(spec(ip), listeners);
      expect(built.issues, isEmpty);
      final route = jsonDecode(built.json!)['route'] as Map;
      expect(route.containsKey('rule_set'), isFalse);
      expect(route['rules'][2], {'action': 'resolve'});
      expect(route['rules'], hasLength(4));
      final flagged = await builder.build(
        spec(domain, noResolve: true),
        listeners,
      );
      expect(flagged.issues.single.code, 'unexpected_no_resolve');
      for (final invalid in [
        CoreRuleSetSpec(tag: '', kind: CoreRuleSetKind.domain),
        CoreRuleSetSpec(
          tag: 'bad',
          kind: CoreRuleSetKind.domain,
          domains: [''],
        ),
        CoreRuleSetSpec(
          tag: 'bad',
          kind: CoreRuleSetKind.domain,
          prefixes: ['192.0.2.0/24'],
        ),
        CoreRuleSetSpec(
          tag: 'bad',
          kind: CoreRuleSetKind.ipCidr,
          prefixes: ['192.0.2.0/99'],
        ),
      ]) {
        expect((await builder.build(spec(invalid), listeners)).json, isNull);
      }
      final missing = await builder.build(
        CoreProfileSpec(
          nodes: const [
            CoreNodeSpec(tag: 'chosen', protocol: CoreNodeProtocol.direct),
          ],
          selectors: [],
          finalOutbound: 'chosen',
          rules: const [
            CoreRouteRule(
              kind: CoreRuleKind.ruleSet,
              value: 'missing',
              outbound: 'chosen',
            ),
          ],
        ),
        listeners,
      );
      expect(missing.issues.single.code, 'unknown_rule_set');
    },
  );

  test(
    'domain types, presence attributes, country inversion and dual-family prefixes survive decoding',
    () async {
      final site = await CoreGeoDecoder.decode(
        bytes: geoDatabase('XX', [
          geoDomain(0, 'keyword', attributes: ['active']),
          geoDomain(0, 'UPPER', attributes: ['active']),
          geoDomain(1, r'^ad\d+\.invalid$', attributes: ['active']),
          geoDomain(2, 'ROOT.INVALID', attributes: ['active']),
          geoDomain(3, 'EXACT.INVALID'),
        ]),
        requests: [
          CoreGeoRequest.parse(CoreGeoKind.site, 'xx')!,
          CoreGeoRequest.parse(CoreGeoKind.site, '!XX@active')!,
          CoreGeoRequest.parse(CoreGeoKind.site, 'xx@missing')!,
        ],
      );
      expect(site['site:xx']!.set.domains, ['exact.invalid']);
      expect(site['site:xx']!.set.suffixes, ['root.invalid']);
      final selected = site['site:!xx@active']!;
      expect(selected.inverted, isTrue);
      expect(selected.set.domains, isEmpty);
      expect(selected.set.keywords, ['keyword', 'UPPER']);
      expect(selected.set.regexes, [r'^ad\d+\.invalid$']);
      expect(site['site:xx@missing']!.set.isEmpty, isTrue);
      expect(() => selected.set.keywords.add('mutate'), throwsUnsupportedError);
      final ips = await CoreGeoDecoder.decode(
        bytes: geoDatabase('XX', [
          geoPrefix([192, 0, 2, 0], 24),
          geoPrefix([0x20, 1, 0x0d, 0xb8, ...List.filled(12, 0)], 32),
        ], reverse: true),
        requests: [
          CoreGeoRequest.parse(CoreGeoKind.ip, 'xx')!,
          CoreGeoRequest.parse(CoreGeoKind.ip, '!xx')!,
        ],
      );
      expect(ips['ip:xx']!.inverted, isFalse);
      expect(ips['ip:!xx']!.inverted, isTrue);
      expect(ips['ip:xx']!.set.prefixes, ['192.0.2.0/24', '2001:db8::/32']);
      for (final invalid in [
        '',
        '!',
        '../private/key',
        'cn@a/b',
        'cn,secret',
      ]) {
        expect(CoreGeoRequest.parse(CoreGeoKind.site, invalid), isNull);
      }
      expect(CoreGeoRequest.parse(CoreGeoKind.ip, 'cn@tag'), isNull);
    },
  );

  test(
    'truncated protobuf, unsupported wires and invalid matchers never become partial results',
    () async {
      final request = CoreGeoRequest.parse(CoreGeoKind.site, 'xx')!;
      for (final bytes in [
        Uint8List.fromList([0]),
        Uint8List.fromList(List.filled(11, 255)),
        Uint8List.fromList([0x0a, 8, 1]),
        Uint8List.fromList([0x0b]),
        Uint8List.fromList([
          ...geoVarint((17 << 3) | 2),
          ...List.filled(9, 0xff),
          1,
        ]),
        geoDatabase('XX', [geoDomain(7, 'invalid')]),
        geoDatabase('XX', [
          geoBytes(2, [0xff]),
        ]),
        Uint8List.fromList([
          ...geoDatabase('XX', []),
          ...geoDatabase('xx', []),
        ]),
      ]) {
        await expectLater(
          CoreGeoDecoder.decode(bytes: bytes, requests: [request]),
          throwsFormatException,
        );
      }
      await expectLater(
        CoreGeoDecoder.decode(
          bytes: geoDatabase('YY', []),
          requests: [request],
        ),
        throwsFormatException,
      );
      await expectLater(
        CoreGeoDecoder.decode(
          bytes: geoDatabase('XX', [
            geoPrefix([1, 2, 3], 24),
          ]),
          requests: [CoreGeoRequest.parse(CoreGeoKind.ip, 'xx')!],
        ),
        throwsFormatException,
      );
      final unknown = Uint8List.fromList([
        ...geoBytes(17, [1, 2, 3]),
        ...geoNumber(18, 1),
        ...geoVarint((19 << 3) | 1),
        ...List.filled(8, 0),
        ...geoVarint((20 << 3) | 5),
        ...List.filled(4, 0),
        ...geoDatabase('XX', [geoDomain(3, 'known.invalid')]),
      ]);
      expect(
        (await CoreGeoDecoder.decode(
          bytes: unknown,
          requests: [request],
        ))[request.key]!.set.domains,
        ['known.invalid'],
      );
    },
  );

  test(
    'application-owned files and source rules retain set order and conservative offline results',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'hotaru-geodata-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final site = await File('${directory.path}/site.dat').writeAsBytes(
        geoDatabase('XX', [
          geoDomain(2, 'root.invalid'),
          geoDomain(1, r'^ad\d+\.invalid$'),
        ]),
      );
      final ip = await File('${directory.path}/ip.dat').writeAsBytes(
        geoDatabase('XX', [
          geoPrefix([192, 0, 2, 0], 24),
        ]),
      );
      final files = CoreGeoDataFiles(
        geoIpPath: ip.path,
        geoSitePath: site.path,
      );
      const source =
          'geodata-mode: true\nrules: ["GEOSITE,xx,DIRECT", "GEOIP,xx,DIRECT,no-resolve", "MATCH,REJECT"]';
      final imported = await ClashProfileImporter().import(
        source,
        resolveGeo: files.resolve,
      );
      expect(imported.issues, isEmpty);
      expect(imported.profile!.ruleSets, hasLength(2));
      expect(imported.profile!.rules.map((rule) => rule.kind), [
        CoreRuleKind.ruleSet,
        CoreRuleKind.ruleSet,
        CoreRuleKind.always,
      ]);
      final preview = CoreRoutePreviewer();
      expect(
        (await preview.preview(imported.profile!, 'child.root.invalid')).chain,
        ['DIRECT'],
      );
      expect(
        (await preview.preview(imported.profile!, 'other.invalid')).status,
        CoreRoutePreviewStatus.contextRequired,
      );
      expect((await preview.preview(imported.profile!, '192.0.2.1')).chain, [
        'DIRECT',
      ]);
      final missing = await ClashProfileImporter().import(source);
      expect(missing.profile, isNull);
      expect(missing.issues.first.code, 'geo_data_required');
      final failure = await ClashProfileImporter().import(
        source,
        resolveGeo: (_) async => throw StateError('private file/secret'),
      );
      expect(failure.profile, isNull);
      expect(failure.issues.single.code, 'geo_data_resolution_failed');
      expect(failure.issues.single.path, 'geodata');
    },
  );

  test(
    'bundled databases agree with independently decoded protobuf reference digests',
    () async {
      final files = CoreGeoDataFiles(
        geoIpPath: '${Directory.current.path}/assets/data/GEOIP.dat',
        geoSitePath: '${Directory.current.path}/assets/data/GEOSITE.dat',
      );
      final data = await files.resolve([
        CoreGeoRequest.parse(CoreGeoKind.ip, 'cn')!,
        for (final country in ['cn', 'google', 'google@cn', 'category-ads-all'])
          CoreGeoRequest.parse(CoreGeoKind.site, country)!,
      ]);
      const expected = {
        'ip:cn':
            '21730fd3e60ef7c18636d1c5bdf9560c8aa2da63c1d1f92e7faefd52f4bf52c5',
        'site:cn':
            '863c99d761c968df18c0f131c035cb618d1063be7c145d3632412b8961a015ac',
        'site:google':
            '700ce2e2a472608380212757200d010c2ffff150a2666bee8f88e1d1170a6b17',
        'site:google@cn':
            '24e24f952052550fa9c6c80bc59eadb1a97c930a1367e33eb7b629b8942dbdd6',
        'site:category-ads-all':
            'ba306913004bf9814c1a4b2f19ea954c0c11f11bbc738cbdefa39d94214d88c3',
      };
      for (final entry in expected.entries) {
        final set = data[entry.key]!.set;
        final text = StringBuffer();
        for (final field in {
          'domains': set.domains,
          'suffixes': set.suffixes,
          'keywords': set.keywords,
          'regexes': set.regexes,
          'prefixes': set.prefixes,
        }.entries) {
          for (final value in field.value.toList()..sort()) {
            text.writeln('${field.key}:$value');
          }
        }
        expect(
          sha256.convert(utf8.encode(text.toString())).toString(),
          entry.value,
          reason: entry.key,
        );
      }
      final binary = Platform.environment['HOTARU_TEST_SING_BOX'];
      if (binary != null) {
        final directory = await Directory.systemTemp.createTemp(
          'hotaru-geo-native-',
        );
        try {
          final built = await SingBoxConfigBuilder().build(
            CoreProfileSpec(
              nodes: const [
                CoreNodeSpec(tag: 'direct', protocol: CoreNodeProtocol.direct),
              ],
              selectors: [],
              finalOutbound: 'direct',
              ruleSets: [for (final value in data.values) value.set],
              rules: [
                for (final value in data.values)
                  CoreRouteRule(
                    kind: CoreRuleKind.ruleSet,
                    value: value.set.tag,
                    outbound: 'direct',
                    noResolve: value.set.requiresAddress,
                  ),
              ],
            ),
            const CoreListenerSpec(
              mixedPort: 17890,
              controllerPort: 19090,
              secret: 'fixture',
            ),
          );
          expect(built.issues, isEmpty);
          final config = await File(
            '${directory.path}/config.json',
          ).writeAsString(built.json!);
          final result = await Process.run(binary, [
            'check',
            '-c',
            config.path,
          ]);
          expect(result.exitCode, 0, reason: '${result.stderr}');
        } finally {
          await directory.delete(recursive: true);
        }
      }
    },
  );
}
