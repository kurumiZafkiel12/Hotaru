import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/config/clash_rule_sets.dart';
import 'package:hotaru/core/config/clash_subscription.dart';
import 'package:hotaru/core/config/profile.dart';
import 'package:hotaru/core/config/route_preview.dart';
import 'package:hotaru/core/sing_box/config_builder.dart';

Map<String, dynamic> document(
  Map<String, dynamic> providers, {
  List<String>? rules,
}) => {
  'proxies': [
    {'name': 'proxy', 'type': 'http', 'server': '127.0.0.1', 'port': 18888},
  ],
  'rule-providers': providers,
  'rules':
      rules ??
      ['DOMAIN,first.invalid,DIRECT', 'RULE-SET,remote,proxy', 'MATCH,DIRECT'],
};
Map<String, dynamic> remote({
  String behavior = 'domain',
  String format = 'yaml',
}) => {
  'type': 'http',
  'url': 'https://fixture.invalid/rules',
  'proxy': 'DIRECT',
  'behavior': behavior,
  'format': format,
  'interval': 1800,
};
Future<CoreConfigImportResult> convert(
  Map<String, dynamic> source, {
  CoreRuleProviderResolver? resolver,
}) => ClashSubscriptionImporter(
  resolve: (_) => throw StateError('No proxy downloads'),
  resolveRules: resolver,
).import(jsonEncode(source));

void main() {
  test(
    'HTTP domain expansion keeps exact/suffix order, routing and defaults',
    () async {
      final port = ReceivePort();
      addTearDown(port.close);
      final seen = <CoreRuleProviderRequest>[];
      final result = await convert(
        document({'remote': remote()}),
        resolver: (request) async {
          expect(port.sendPort, isNotNull);
          seen.add(request);
          return 'payload:\n  - first.invalid\n  - +.example.invalid\n  - exact.invalid\n';
        },
      );
      expect(result.issues, isEmpty);
      expect(seen.single.outbound, 'DIRECT');
      expect(seen.single.interval, const Duration(minutes: 30));
      expect(seen.single.maxBytes, 16 * 1024 * 1024);
      final profile = result.profile!;
      expect(profile.rules.map((rule) => rule.kind), [
        CoreRuleKind.domain,
        CoreRuleKind.domain,
        CoreRuleKind.domainSuffix,
        CoreRuleKind.domain,
      ]);
      final preview = CoreRoutePreviewer();
      expect(
        (await preview.preview(profile, 'first.invalid')).chain.last,
        'DIRECT',
      );
      for (final host in [
        'example.invalid',
        'sub.example.invalid',
        'exact.invalid',
      ]) {
        expect((await preview.preview(profile, host)).chain.last, 'proxy');
      }
      expect(
        (await preview.preview(profile, 'sub.exact.invalid')).chain.last,
        'DIRECT',
      );
      expect(
        (await preview.preview(profile, 'notexample.invalid')).chain.last,
        'DIRECT',
      );
      final built = await SingBoxConfigBuilder().build(
        profile,
        const CoreListenerSpec(
          mixedPort: 17890,
          controllerPort: 19090,
          secret: 'fixture',
        ),
      );
      expect(built.issues, isEmpty);
      expect(jsonDecode(built.json!)['route']['rules'][2]['domain_suffix'], [
        'example.invalid',
      ]);
    },
  );

  test(
    'inline classical rules inherit action without accepting nested targets',
    () async {
      final result = await convert(
        document(
          {
            'remote': {
              'type': 'inline',
              'behavior': 'classical',
              'payload': [
                'DOMAIN,blocked.invalid',
                'DOMAIN-SUFFIX,example.invalid',
                'DOMAIN-KEYWORD,word',
              ],
            },
          },
          rules: ['RULE-SET,remote,REJECT', 'MATCH,DIRECT'],
        ),
      );
      expect(result.issues, isEmpty);
      expect(
        result.profile!.rules.every(
          (rule) => rule.action == CoreRuleAction.reject,
        ),
        isTrue,
      );
    },
  );

  test('text payload accepts whole-line comments and CRLF', () async {
    final result = await convert(
      document({'remote': remote(format: 'text')}),
      resolver: (_) async =>
          '# comment\r\n\r\n+.example.invalid\r\nexact.invalid\r\n',
    );
    expect(result.issues, isEmpty);
    expect(result.profile!.rules.length, 3);
  });

  test(
    'file resolver receives relative path and no network authority',
    () async {
      final result = await convert(
        document({
          'remote': {
            'type': 'file',
            'path': 'rules/domains.yaml',
            'behavior': 'domain',
          },
        }),
        resolver: (request) async {
          expect(request.url, isNull);
          expect(request.path, 'rules/domains.yaml');
          return 'payload: [exact.invalid]';
        },
      );
      expect(result.issues, isEmpty);
    },
  );

  test(
    'missing resolver and failed downloads produce no replacement',
    () async {
      final source = document({'remote': remote()});
      for (final resolver in <CoreRuleProviderResolver?>[
        null,
        (_) async => throw StateError('503'),
      ]) {
        final result = await convert(source, resolver: resolver);
        expect(result.profile, isNull);
        expect(
          result.issues.any((issue) => issue.code.startsWith('rule_provider_')),
          isTrue,
        );
      }
    },
  );

  test('unsupported rules or one bad member fail the entire profile', () async {
    for (final payload in [
      'payload: [valid.invalid, "*.invalid"]',
      'payload: [".invalid"]',
      'payload: ["IP-CIDR,192.0.2.0/24"]',
      'payload: [1]',
      'payload: [bad/domain]',
      'payload: ["+"]',
      'payload: [good.invalid]\nextra: true',
      'payload: [',
      'payload: wrong',
    ]) {
      final result = await convert(
        document({'remote': remote()}),
        resolver: (_) async => payload,
      );
      expect(result.profile, isNull, reason: payload);
    }
  });

  test(
    'classical payload cannot override action or inject MATCH/logical rules',
    () async {
      for (final entry in [
        'DOMAIN,example.invalid,DIRECT',
        'MATCH',
        'AND,((DOMAIN,a.invalid))',
        'IP-CIDR,192.0.2.0/24',
        'DOMAIN-KEYWORD,',
      ]) {
        final result = await convert(
          document({
            'remote': {
              'type': 'inline',
              'behavior': 'classical',
              'payload': [entry],
            },
          }),
        );
        expect(result.profile, isNull, reason: entry);
      }
    },
  );

  test(
    'unknown settings, traversal and unsupported formats are not approximated',
    () async {
      for (final provider in [
        {...remote(), 'behavior': 'ipcidr'},
        {...remote(), 'format': 'mrs'},
        {...remote(), 'header': {}},
        {...remote(), 'url': 'https://name:secret@fixture.invalid/rules'},
        {'type': 'file', 'path': '../rules.yaml', 'behavior': 'domain'},
        {
          'type': 'inline',
          'behavior': 'domain',
          'payload': [],
          'url': 'https://fixture.invalid',
        },
      ]) {
        var calls = 0;
        final result = await convert(
          document({'remote': provider}),
          resolver: (_) async {
            calls++;
            return 'payload: []';
          },
        );
        expect(result.profile, isNull);
        expect(calls, 0);
      }
    },
  );

  test('rules after MATCH stay invalid even for an empty rule-set', () async {
    final result = await convert(
      document(
        {
          'remote': {'type': 'inline', 'behavior': 'domain', 'payload': []},
        },
        rules: ['MATCH,DIRECT', 'RULE-SET,remote,proxy'],
      ),
    );
    expect(result.profile, isNull);
    expect(
      result.issues.map((issue) => issue.code),
      contains('rule_after_final'),
    );
  });

  test('missing references and rule-set modifiers fail explicitly', () async {
    for (final rule in [
      'RULE-SET,missing,proxy',
      'RULE-SET,remote,proxy,no-resolve',
    ]) {
      final result = await convert(
        document(
          {
            'remote': {'type': 'inline', 'behavior': 'domain', 'payload': []},
          },
          rules: [rule, 'MATCH,DIRECT'],
        ),
      );
      expect(result.profile, isNull);
      expect(
        result.issues.map((issue) => issue.code),
        contains('invalid_rule_set_reference'),
      );
    }
  });

  test(
    'download concurrency is bounded and timeout stops scheduling',
    () async {
      var active = 0;
      var peak = 0;
      final expanded =
          await ClashRuleSetImporter(
            concurrency: 2,
            resolve: (_) async {
              active++;
              if (active > peak) peak = active;
              await Future<void>.delayed(const Duration(milliseconds: 5));
              active--;
              return 'payload: [exact.invalid]';
            },
          ).expand(
            document(
              {for (var i = 0; i < 5; i++) '$i': remote()},
              rules: ['MATCH,DIRECT'],
            ),
          );
      expect(expanded.issues, isEmpty);
      expect(peak, 2);
      var calls = 0;
      final timed = await ClashRuleSetImporter(
        concurrency: 1,
        timeout: const Duration(milliseconds: 5),
        resolve: (_) {
          calls++;
          return Completer<String>().future;
        },
      ).expand(document({'a': remote(), 'b': remote()}));
      expect(timed.document, isNull);
      expect(calls, 1);
    },
  );

  test('caps provider count, payload size and expanded fan-out', () async {
    final tooMany = await convert(
      document({for (var i = 0; i < 65; i++) '$i': remote()}),
    );
    expect(tooMany.profile, isNull);
    final large = await convert(
      document({'remote': remote()}),
      resolver: (_) async => 'a' * (16 * 1024 * 1024 + 1),
    );
    expect(
      large.issues.map((issue) => issue.code),
      contains('rule_provider_payload_too_large'),
    );
    final expanded = await convert(
      document(
        {
          'remote': {
            'type': 'inline',
            'behavior': 'domain',
            'payload': List.filled(1000, 'exact.invalid'),
          },
        },
        rules: [...List.filled(251, 'RULE-SET,remote,proxy'), 'MATCH,DIRECT'],
      ),
    );
    expect(expanded.profile, isNull);
    expect(
      expanded.issues.map((issue) => issue.code),
      contains('expanded_rule_limit_exceeded'),
    );
  });
}
