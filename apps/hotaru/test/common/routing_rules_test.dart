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

  test(
    'Shadowrocket sections and remote lists become independent Mihomo rules',
    () {
      final result = RoutingRules.parse('''
# Example configuration
[General]
dns-server = system
[Rule] # routing only
DOMAIN-SUFFIX,example.cn,Direct
DOMAIN,blocked.test,Reject
IP6-CIDR,2001:db8::/32,Proxy,no-resolve
DEST-PORT,443,Proxy
RULE-SET,https://example.com/domestic.list,DIRECT,no-resolve
FINAL,Proxy
[URL Rewrite]
^https://example.com https://example.org 302
''').apply(subscription, 'Selected');
      expect(result['rules'], [
        'DOMAIN-SUFFIX,example.cn,DIRECT',
        'DOMAIN,blocked.test,REJECT',
        'IP-CIDR6,2001:db8::/32,Selected,no-resolve',
        'DST-PORT,443,Selected',
        'RULE-SET,hotaru-conf-1,DIRECT,no-resolve',
        'MATCH,Selected',
      ]);
      expect((result['rule-providers'] as Map)['hotaru-conf-1'], {
        'type': 'http',
        'behavior': 'classical',
        'format': 'text',
        'url': 'https://example.com/domestic.list',
        'interval': 86400,
      });
      expect(result['dns'], subscription['dns']);
      expect(result, isNot(contains('URL Rewrite')));
    },
  );

  test(
    'unsupported Shadowrocket rules fail with a source line instead of being skipped',
    () {
      for (final rule in [
        'USER-AGENT,Example*,Proxy',
        'URL-REGEX,^https://example.com,REJECT',
        'DOMAIN,example.com,REJECT-TINYGIF',
        'FINAL,Proxy,dns-failed',
        'RULE-SET,file:///private.list,Proxy',
      ]) {
        expect(
          () => RoutingRules.parse('[Rule]\n$rule\nFINAL,Proxy'),
          throwsA(
            isA<UnsupportedRoutingRule>().having(
              (error) => error.line,
              'line',
              2,
            ),
          ),
        );
      }
    },
  );
}
