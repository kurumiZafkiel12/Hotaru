import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/config/clash_importer.dart';
import 'package:hotaru/core/config/clash_subscription.dart';
import 'package:hotaru/core/config/ip_prefix.dart';
import 'package:hotaru/core/config/profile.dart';
import 'package:hotaru/core/config/route_preview.dart';
import 'package:hotaru/core/sing_box/config_builder.dart';

CoreProfileSpec profile(List<CoreRouteRule> rules) => CoreProfileSpec(
  nodes: const [
    CoreNodeSpec(tag: 'chosen', protocol: CoreNodeProtocol.direct),
    CoreNodeSpec(tag: 'fallback', protocol: CoreNodeProtocol.direct),
  ],
  selectors: [],
  finalOutbound: 'fallback',
  rules: rules,
);
const listeners = CoreListenerSpec(
  mixedPort: 17890,
  controllerPort: 19090,
  secret: 'ip-fixture',
);
Future<CoreConfigImportResult> importRules(
  Map<String, dynamic> provider,
  List<String> rules,
) =>
    ClashSubscriptionImporter(
      resolve: (_) async => throw StateError('Inline only'),
    ).import(
      jsonEncode({
        'rule-providers': {'ips': provider},
        'rules': rules,
      }),
    );

void main() {
  test('CIDR parser agrees with strict prefix syntax and family bounds', () {
    for (final value in [
      '192.0.2.1/32',
      '192.0.2.129/25',
      '0.0.0.0/0',
      '::/0',
      '2001:db8::1/128',
    ]) {
      expect(CoreIpPrefix.parse(value), isNotNull, reason: value);
    }
    for (final value in [
      '192.0.2.1',
      '192.0.2.0/+24',
      '192.0.2.0/024',
      '192.0.2.0/-1',
      '192.0.2.0/33',
      '2001:db8::/129',
      '192.000.2.0/24',
      'fe80::%eth0/64',
      '[::1]/128',
      '::ffff:192.0.2.0/120',
      'a.invalid/24',
    ]) {
      expect(CoreIpPrefix.parse(value), isNull, reason: value);
    }
    expect(
      CoreIpPrefix.parse(
        '192.0.2.129/25',
      )!.contains(InternetAddress('192.0.2.255')),
      isTrue,
    );
    expect(
      CoreIpPrefix.parse(
        '192.0.2.129/25',
      )!.contains(InternetAddress('192.0.2.127')),
      isFalse,
    );
    expect(
      CoreIpPrefix.parse('::/0')!.contains(InternetAddress('192.0.2.1')),
      isFalse,
    );
  });

  test(
    'plain IP rules retain resolution intent separately from no-resolve',
    () async {
      for (final type in ['IP-CIDR', 'IP-CIDR6']) {
        final source =
            '$type,${type.endsWith('6') ? '2001:db8::/32' : '192.0.2.0/24'},DIRECT';
        final resolving = await ClashProfileImporter().import(
          jsonEncode({
            'rules': [source, 'MATCH,DIRECT'],
          }),
        );
        expect(resolving.issues.single.code, 'ip_resolution_semantics_changed');
        expect(
          resolving.issues.single.severity,
          CoreConfigIssueSeverity.warning,
        );
        expect(resolving.profile!.rules.single.noResolve, isFalse);
        final built = await SingBoxConfigBuilder().build(
          resolving.profile!,
          listeners,
        );
        expect(built.issues, isEmpty);
        final rules = jsonDecode(built.json!)['route']['rules'] as List;
        expect(rules[2], {'action': 'resolve'});
        expect(rules[3]['ip_cidr'], [source.split(',')[1]]);
        final accepted = await ClashProfileImporter().import(
          jsonEncode({
            'rules': ['$source,no-resolve', 'MATCH,DIRECT'],
          }),
        );
        expect(accepted.issues, isEmpty);
        expect(accepted.profile!.rules.single.noResolve, isTrue);
        expect(
          (await SingBoxConfigBuilder().build(
            accepted.profile!,
            listeners,
          )).issues,
          isEmpty,
        );
      }
    },
  );

  test(
    'builder resolves IP rules at their position and rejects unused no-resolve fields',
    () async {
      final resolving = await SingBoxConfigBuilder().build(
        profile(const [
          CoreRouteRule(
            kind: CoreRuleKind.ipCidr,
            value: '192.0.2.0/24',
            outbound: 'chosen',
          ),
        ]),
        listeners,
      );
      expect(resolving.issues, isEmpty);
      expect(jsonDecode(resolving.json!)['route']['rules'][2], {
        'action': 'resolve',
      });
      final unused = await SingBoxConfigBuilder().build(
        profile(const [
          CoreRouteRule(
            kind: CoreRuleKind.domain,
            value: 'fixture.invalid',
            outbound: 'chosen',
            noResolve: true,
          ),
        ]),
        listeners,
      );
      expect(unused.issues.single.code, 'unexpected_no_resolve');
      final malformed = await SingBoxConfigBuilder().build(
        profile(const [
          CoreRouteRule(
            kind: CoreRuleKind.ipCidr,
            value: '192.0.2.0/99',
            outbound: 'chosen',
            noResolve: true,
          ),
        ]),
        listeners,
      );
      expect(malformed.issues.single.code, 'invalid_ip_prefix');
    },
  );

  test(
    'ipcidr sets preserve no-resolve or require review of native resolution',
    () async {
      final provider = {
        'type': 'inline',
        'behavior': 'ipcidr',
        'payload': ['192.0.2.0/24', '2001:db8::/32'],
      };
      final accepted = await importRules(provider, [
        'RULE-SET,ips,DIRECT,no-resolve',
        'MATCH,DIRECT',
      ]);
      expect(accepted.issues, isEmpty);
      expect(accepted.profile!.rules.map((rule) => rule.value), [
        '192.0.2.0/24',
        '2001:db8::/32',
      ]);
      expect(accepted.profile!.rules.every((rule) => rule.noResolve), isTrue);
      final resolving = await importRules(provider, [
        'RULE-SET,ips,DIRECT',
        'MATCH,DIRECT',
      ]);
      expect(resolving.profile, isNotNull);
      expect(resolving.issues.map((issue) => issue.code), [
        'ip_resolution_semantics_changed',
        'ip_resolution_semantics_changed',
      ]);
      final built = await SingBoxConfigBuilder().build(
        resolving.profile!,
        listeners,
      );
      expect(built.issues, isEmpty);
      final native = jsonDecode(built.json!)['route']['rules'] as List;
      expect(
        native.where((dynamic rule) => rule['action'] == 'resolve'),
        hasLength(1),
      );
      final empty = await importRules(
        {'type': 'inline', 'behavior': 'ipcidr', 'payload': []},
        ['RULE-SET,ips,DIRECT', 'MATCH,DIRECT'],
      );
      expect(empty.profile, isNull);
      expect(empty.issues.single.code, 'empty_resolving_rule_set_not_migrated');
    },
  );

  test(
    'classical reference and per-entry no-resolve flags preserve order and actions',
    () async {
      for (final referenceFlag in [false, true]) {
        final result = await importRules(
          {
            'type': 'inline',
            'behavior': 'classical',
            'payload': [
              'DOMAIN,first.invalid',
              'IP-CIDR,192.0.2.0/24${referenceFlag ? '' : ',no-resolve'}',
              'DOMAIN-SUFFIX,last.invalid',
            ],
          },
          [
            'RULE-SET,ips,REJECT-DROP${referenceFlag ? ',no-resolve' : ''}',
            'MATCH,DIRECT',
          ],
        );
        expect(result.issues, isEmpty);
        expect(result.profile!.rules.map((rule) => rule.kind), [
          CoreRuleKind.domain,
          CoreRuleKind.ipCidr,
          CoreRuleKind.domainSuffix,
        ]);
        expect(result.profile!.rules[1].noResolve, isTrue);
        expect(
          result.profile!.rules.every(
            (rule) => rule.action == CoreRuleAction.drop,
          ),
          isTrue,
        );
      }
      final resolving = await importRules(
        {
          'type': 'inline',
          'behavior': 'classical',
          'payload': ['IP-CIDR,192.0.2.0/24'],
        },
        ['RULE-SET,ips,DIRECT', 'MATCH,DIRECT'],
      );
      expect(resolving.profile, isNotNull);
      expect(resolving.issues.single.code, 'ip_resolution_semantics_changed');
      expect(resolving.profile!.rules.single.noResolve, isFalse);
    },
  );

  test('bad prefixes or classical modifiers fail the whole profile', () async {
    for (final entry in [
      'IP-CIDR,192.0.2.0/99,no-resolve',
      'IP-CIDR,192.0.2.0/24,other',
      'IP-CIDR6,::/129',
      'IP-CIDR',
    ]) {
      final result = await importRules(
        {
          'type': 'inline',
          'behavior': 'classical',
          'payload': [entry],
        },
        ['RULE-SET,ips,DIRECT,no-resolve', 'MATCH,DIRECT'],
      );
      expect(result.profile, isNull, reason: entry);
    }
  });

  test(
    'preview skips no-resolve IP rules for domains but matches literal prefixes',
    () async {
      final spec = profile(const [
        CoreRouteRule(
          kind: CoreRuleKind.ipCidr,
          value: '192.0.2.0/24',
          outbound: 'chosen',
          noResolve: true,
        ),
        CoreRouteRule(
          kind: CoreRuleKind.domain,
          value: 'domain.invalid',
          outbound: 'fallback',
        ),
      ]);
      final preview = CoreRoutePreviewer();
      expect((await preview.preview(spec, '192.0.2.5')).chain, ['chosen']);
      expect((await preview.preview(spec, '192.0.3.5')).chain, ['fallback']);
      final domain = await preview.preview(spec, 'domain.invalid');
      expect(domain.status, CoreRoutePreviewStatus.resolved);
      expect(domain.ruleIndex, 1);
      expect(domain.chain, ['fallback']);
      expect((await preview.preview(spec, 'unknown.invalid')).chain, [
        'fallback',
      ]);
      expect(
        (await preview.preview(spec, '::ffff:192.0.2.5')).status,
        CoreRoutePreviewStatus.invalidTarget,
      );
    },
  );

  test(
    'HTTP text ipcidr payloads retain file/network authority and flags',
    () async {
      final result =
          await ClashSubscriptionImporter(
            resolve: (_) async => throw StateError('No proxies'),
            resolveRules: (request) async {
              expect(request.behavior, 'ipcidr');
              expect(request.format, 'text');
              return '# prefix set\n192.0.2.0/24\n2001:db8::/32\n';
            },
          ).import(
            jsonEncode({
              'rule-providers': {
                'ips': {
                  'type': 'http',
                  'url': 'https://fixture.invalid/ips',
                  'behavior': 'ipcidr',
                  'format': 'text',
                },
              },
              'rules': ['RULE-SET,ips,DIRECT,no-resolve', 'MATCH,DIRECT'],
            }),
          );
      expect(result.issues, isEmpty);
      expect(result.profile!.rules.length, 2);
    },
  );
}
