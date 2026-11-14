import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/config/profile.dart';
import 'package:hotaru/core/config/route_preview.dart';

CoreProfileSpec _profile({
  List<CoreRouteRule> rules = const [],
  List<CoreSelectorSpec> groups = const [],
  String finalOutbound = 'direct',
}) => CoreProfileSpec(
  nodes: const [
    CoreNodeSpec(tag: 'direct', protocol: CoreNodeProtocol.direct),
    CoreNodeSpec(
      tag: 'node',
      protocol: CoreNodeProtocol.http,
      server: 'fixture.invalid',
      port: 443,
    ),
  ],
  selectors: groups,
  finalOutbound: finalOutbound,
  rules: rules,
);

void main() {
  final previewer = CoreRoutePreviewer();

  test('uses first matching rule, not a more specific later rule', () async {
    final result = await previewer.preview(
      _profile(
        rules: const [
          CoreRouteRule(
            kind: CoreRuleKind.domainSuffix,
            value: 'example.com',
            outbound: 'node',
          ),
          CoreRouteRule(
            kind: CoreRuleKind.domain,
            value: 'www.example.com',
            outbound: 'direct',
          ),
        ],
      ),
      ' WWW.EXAMPLE.COM ',
    );
    expect(result.status, CoreRoutePreviewStatus.resolved);
    expect(result.target, 'www.example.com');
    expect(result.ruleIndex, 0);
    expect(result.chain, ['node']);
  });

  test('suffix matching respects label boundaries and leading dot', () async {
    for (final value in ['example.com', '.example.com']) {
      final profile = _profile(
        rules: [
          CoreRouteRule(
            kind: CoreRuleKind.domainSuffix,
            value: value,
            outbound: 'node',
          ),
        ],
      );
      final subdomain = await previewer.preview(profile, 'a.example.com');
      expect(subdomain.chain, ['node']);
      final unrelated = await previewer.preview(profile, 'notexample.com');
      expect(unrelated.chain, ['direct']);
      final root = await previewer.preview(profile, 'example.com');
      expect(root.chain, [value.startsWith('.') ? 'direct' : 'node']);
    }
  });

  test('keywords and rule values follow the compiled engine case', () async {
    final result = await previewer.preview(
      _profile(
        rules: const [
          CoreRouteRule(
            kind: CoreRuleKind.domainKeyword,
            value: 'EXAMPLE',
            outbound: 'direct',
          ),
          CoreRouteRule(
            kind: CoreRuleKind.domainKeyword,
            value: 'example',
            outbound: 'node',
          ),
        ],
      ),
      'EXAMPLE.COM',
    );
    expect(result.ruleIndex, 1);
    expect(result.chain, ['node']);
  });

  test('does not skip an earlier IP rule or resolve the domain', () async {
    final result = await previewer.preview(
      _profile(
        rules: const [
          CoreRouteRule(
            kind: CoreRuleKind.ipCidr,
            value: '192.0.2.0/24',
            outbound: 'node',
          ),
          CoreRouteRule(
            kind: CoreRuleKind.domain,
            value: 'fixture.invalid',
            outbound: 'direct',
          ),
        ],
      ),
      'fixture.invalid',
    );
    expect(result.status, CoreRoutePreviewStatus.addressRequired);
    expect(result.ruleIndex, 0);
    expect(result.chain, isEmpty);
    expect(result.action, isNull);
  });

  test('an earlier domain match needs no DNS for later IP rules', () async {
    final result = await previewer.preview(
      _profile(
        rules: const [
          CoreRouteRule(
            kind: CoreRuleKind.domain,
            value: 'fixture.invalid',
            outbound: 'node',
          ),
          CoreRouteRule(
            kind: CoreRuleKind.ipCidr,
            value: '0.0.0.0/0',
            outbound: 'direct',
          ),
        ],
      ),
      'fixture.invalid',
    );
    expect(result.status, CoreRoutePreviewStatus.resolved);
    expect(result.chain, ['node']);
  });

  test('matches IPv4/IPv6 prefixes including partial octets and /0', () async {
    for (final (cidr, inside, outside) in [
      ('192.0.2.128/25', '192.0.2.255', '192.0.2.127'),
      ('2001:db8:8000::/33', '2001:db8:ffff::1', '2001:db8:7fff::1'),
      ('192.0.2.9/32', '192.0.2.9', '192.0.2.8'),
      ('2001:db8::1/128', '2001:db8::1', '2001:db8::2'),
      ('0.0.0.0/0', '203.0.113.1', '2001:db8::1'),
    ]) {
      final profile = _profile(
        rules: [
          CoreRouteRule(
            kind: CoreRuleKind.ipCidr,
            value: cidr,
            outbound: 'node',
          ),
        ],
      );
      expect((await previewer.preview(profile, inside)).chain, ['node']);
      expect((await previewer.preview(profile, outside)).chain, ['direct']);
    }
  });

  test('returns reject/drop without inventing an outbound chain', () async {
    for (final action in [CoreRuleAction.reject, CoreRuleAction.drop]) {
      final result = await previewer.preview(
        _profile(
          rules: [
            CoreRouteRule(kind: CoreRuleKind.always, value: '', action: action),
          ],
        ),
        'fixture.invalid',
      );
      expect(result.status, CoreRoutePreviewStatus.resolved);
      expect(result.action, action);
      expect(result.chain, isEmpty);
    }
  });

  test(
    'resolves nested groups using only the supplied selection snapshot',
    () async {
      final selections = {'selected': 'automatic', 'automatic': 'node'};
      final pending = previewer.preview(
        _profile(
          finalOutbound: 'selected',
          groups: [
            CoreSelectorSpec(tag: 'selected', members: ['automatic']),
            CoreSelectorSpec(
              tag: 'automatic',
              members: ['node', 'direct'],
              strategy: CoreGroupStrategy.urltest,
            ),
          ],
        ),
        'fixture.invalid',
        selections: selections,
      );
      selections['automatic'] = 'direct';
      final result = await pending;
      expect(result.status, CoreRoutePreviewStatus.resolved);
      expect(result.ruleIndex, isNull);
      expect(result.chain, ['selected', 'automatic', 'node']);
      expect(() => result.chain.add('other'), throwsUnsupportedError);
    },
  );

  test(
    'never assumes configured/default selection is the running selection',
    () async {
      final result = await previewer.preview(
        _profile(
          finalOutbound: 'group',
          groups: [
            CoreSelectorSpec(tag: 'group', members: ['node'], selected: 'node'),
          ],
        ),
        'fixture.invalid',
      );
      expect(result.status, CoreRoutePreviewStatus.selectionRequired);
      expect(result.chain, ['group']);
    },
  );

  test(
    'unknown destinations, stale selections and cycles fail closed',
    () async {
      for (final (groups, selections) in [
        (<CoreSelectorSpec>[], <String, String>{}),
        (
          [
            CoreSelectorSpec(tag: 'group', members: ['node']),
          ],
          {'group': 'gone'},
        ),
        (
          [
            CoreSelectorSpec(tag: 'group', members: ['group']),
          ],
          {'group': 'group'},
        ),
      ]) {
        final result = await previewer.preview(
          _profile(groups: groups, finalOutbound: 'group'),
          'fixture.invalid',
          selections: selections,
        );
        expect(result.status, CoreRoutePreviewStatus.invalidProfile);
      }
    },
  );

  test(
    'rejects malformed targets without extracting a host from URLs',
    () async {
      for (final target in [
        '',
        'https://example.com/path',
        'example.com:443',
        'a..com',
        '*.com',
        '-example.com',
        'exa mple.com',
        'example.com\n/path',
      ]) {
        final result = await previewer.preview(_profile(), target);
        expect(
          result.status,
          CoreRoutePreviewStatus.invalidTarget,
          reason: target,
        );
      }
    },
  );

  test('invalid CIDRs and duplicate tags cannot produce a route', () async {
    for (final value in ['192.0.2.0/33', '2001:db8::/129', 'bad/24', '::/-1']) {
      final result = await previewer.preview(
        _profile(
          rules: [
            CoreRouteRule(
              kind: CoreRuleKind.ipCidr,
              value: value,
              outbound: 'node',
            ),
          ],
        ),
        '192.0.2.1',
      );
      expect(result.status, CoreRoutePreviewStatus.invalidProfile);
    }
    final result = await previewer.preview(
      _profile(
        groups: [
          CoreSelectorSpec(tag: 'node', members: ['direct']),
        ],
      ),
      'fixture.invalid',
    );
    expect(result.status, CoreRoutePreviewStatus.invalidProfile);
  });
}
