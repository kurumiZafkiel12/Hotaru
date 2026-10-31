import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/common/routing_rules.dart';

void main() {
  const subscription = <String, dynamic>{
    'proxies': [
      {'name': 'Tokyo', 'type': 'ss'},
    ],
    'proxy-groups': [
      {
        'name': 'Selected',
        'type': 'select',
        'proxies': ['Tokyo'],
      },
    ],
    'rules': ['MATCH,OldRule'],
    'rule-providers': {
      'old': {'type': 'http', 'url': 'https://example.com/old'},
    },
    'dns': {'enable': true},
  };
  test(
    'independent routing replaces subscription rules but preserves nodes and direct/reject',
    () {
      final result = RoutingRules.parse('''
rules:
  - DOMAIN-SUFFIX,example.cn,DIRECT
  - DOMAIN,blocked.test,REJECT
  - IP-CIDR,203.0.113.0/24,Overseas,no-resolve
  - MATCH,Proxy
''').apply(subscription, 'Selected');
      expect(result['rules'], [
        'DOMAIN-SUFFIX,example.cn,DIRECT',
        'DOMAIN,blocked.test,REJECT',
        'IP-CIDR,203.0.113.0/24,Selected,no-resolve',
        'MATCH,Selected',
      ]);
      expect(result['proxies'], subscription['proxies']);
      expect(result['proxy-groups'], subscription['proxy-groups']);
      expect(result['dns'], subscription['dns']);
      expect(result['rule-providers'], isEmpty);
      expect(subscription['rules'], ['MATCH,OldRule']);
    },
  );
  test(
    'rule providers and logical/sub-rule payloads retain their semantics',
    () {
      final result = RoutingRules.parse('''
rule-providers:
  domestic: {type: http, behavior: domain, url: https://example.com/rules}
sub-rules:
  nested:
    - DOMAIN-SUFFIX,example.cn,DIRECT
    - MATCH,Proxy
rules:
  - RULE-SET,domestic,DIRECT
  - SUB-RULE,(NETWORK,TCP),nested
  - AND,((DOMAIN,example.com),(NETWORK,TCP)),Proxy
  - MATCH,Proxy
''').apply(subscription, 'Selected');
      expect(result['rules'], [
        'RULE-SET,domestic,DIRECT',
        'SUB-RULE,(NETWORK,TCP),nested',
        'AND,((DOMAIN,example.com),(NETWORK,TCP)),Selected',
        'MATCH,Selected',
      ]);
      expect(result['sub-rules'], {
        'nested': ['DOMAIN-SUFFIX,example.cn,DIRECT', 'MATCH,Selected'],
      });
      expect((result['rule-providers'] as Map).keys, ['domestic']);
    },
  );
  test(
    'malformed or unsupported configuration cannot replace the working rules',
    () {
      for (final source in [
        'invalid',
        'rules: []',
        'rules: [garbage]',
        'rules: ["MATCH"]',
        'rules: ["RULE-SET,missing,DIRECT"]',
        'rules: ["SUB-RULE,(NETWORK,TCP),missing"]',
        'rules: ["MATCH,Proxy"]\nrule-providers: {unsafe: {type: file, path: /outside}}',
      ]) {
        expect(
          () => RoutingRules.parse(source),
          throwsFormatException,
          reason: source,
        );
      }
      expect(
        () => RoutingRules.parse(
          'rules: ["MATCH,Proxy"]',
        ).apply(subscription, 'missing'),
        throwsFormatException,
      );
      expect(subscription['rules'], ['MATCH,OldRule']);
    },
  );
}
