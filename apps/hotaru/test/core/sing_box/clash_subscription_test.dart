import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/config/clash_subscription.dart';
import 'package:hotaru/core/config/profile.dart';
import 'package:hotaru/core/sing_box/config_builder.dart';

Map<String, dynamic> _node(String name) => {
  'name': name,
  'type': 'http',
  'server': '127.0.0.1',
  'port': 14443,
};
String _payload(String name) => jsonEncode({
  'proxies': [_node(name)],
});
String _source(
  Map<String, dynamic> providers, {
  List<Map<String, dynamic>>? groups,
  List<Map<String, dynamic>> proxies = const [],
  Map<String, dynamic> extra = const {},
}) => jsonEncode({
  'proxies': proxies,
  'proxy-providers': providers,
  'proxy-groups':
      groups ??
      [
        {'name': 'Selected', 'type': 'select', 'use': providers.keys.toList()},
      ],
  'rules': ['MATCH,Selected'],
  ...extra,
});
Map<String, dynamic> _http([String suffix = 'fixture']) => {
  'type': 'http',
  'url': 'https://fixture.invalid/$suffix',
  'interval': 1800,
};

void main() {
  test('isolate tasks do not capture the resolver native resources', () async {
    final port = ReceivePort();
    addTearDown(port.close);
    final importer = ClashSubscriptionImporter(
      resolve: (_) async {
        expect(port.sendPort, isNotNull);
        return _payload('Remote');
      },
    );
    final result = await importer.import(_source({'remote': _http()}));
    expect(result.issues, isEmpty);
    expect(result.profile, isNotNull);
  });
  test(
    'expands HTTP providers and produces a validated sing-box profile',
    () async {
      final seen = <CoreProxyProviderRequest>[];
      final importer = ClashSubscriptionImporter(
        resolve: (request) async {
          seen.add(request);
          return _payload('Remote');
        },
      );
      final result = await importer.import(
        _source(
          {
            'remote': {
              ..._http(),
              'proxy': 'DIRECT',
              'header': {
                'Authorization': ['fixture-token'],
              },
            },
          },
          proxies: [_node('Local')],
          groups: [
            {
              'name': 'Selected',
              'type': 'select',
              'proxies': ['Local', 'DIRECT'],
              'use': ['remote'],
            },
          ],
        ),
      );
      expect(result.issues, isEmpty);
      expect(result.profile!.selectors.single.members, [
        'Local',
        'DIRECT',
        'Remote',
      ]);
      expect(seen.single.interval, const Duration(minutes: 30));
      expect(seen.single.timeout, const Duration(seconds: 20));
      expect(seen.single.outbound, 'DIRECT');
      expect(seen.single.headers['Authorization'], ['fixture-token']);
      expect(
        () => seen.single.headers['Authorization']!.add('other'),
        throwsUnsupportedError,
      );
      final built = await SingBoxConfigBuilder().build(
        result.profile!,
        const CoreListenerSpec(
          mixedPort: 17890,
          controllerPort: 19090,
          secret: 'fixture',
        ),
      );
      expect(built.issues, isEmpty);
      final config = jsonDecode(built.json!);
      expect(
        config['outbounds'].map((dynamic node) => node['tag']),
        contains('Remote'),
      );
      expect(built.json, isNot(contains('proxy-providers')));
    },
  );

  test(
    'inline providers need no resolver and include-all ordering matches source',
    () async {
      final importer = ClashSubscriptionImporter(
        resolve: (_) => throw StateError('No IO allowed'),
      );
      final result = await importer.import(
        _source(
          {
            'z': {
              'type': 'inline',
              'payload': [_node('Z')],
            },
            'a': {
              'type': 'inline',
              'payload': [_node('A')],
            },
          },
          proxies: [_node('B-root'), _node('A-root')],
          groups: [
            {
              'name': 'Selected',
              'type': 'select',
              'proxies': ['DIRECT'],
              'use': ['z'],
              'include-all': true,
            },
          ],
        ),
      );
      expect(result.issues, isEmpty);
      expect(result.profile!.selectors.single.members, [
        'DIRECT',
        'A-root',
        'B-root',
        'A',
        'Z',
      ]);
    },
  );

  test(
    'file provider resolution is explicit and scoped to a relative path',
    () async {
      final importer = ClashSubscriptionImporter(
        resolve: (request) async {
          expect(request.kind, CoreProxyProviderKind.file);
          expect(request.path, './providers/local.yaml');
          expect(request.url, isNull);
          return _payload('File');
        },
      );
      final result = await importer.import(
        _source({
          'file': {'type': 'file', 'path': './providers/local.yaml'},
        }),
      );
      expect(result.profile!.selectors.single.members, ['File']);
      expect(result.issues, isEmpty);
    },
  );

  test(
    'unsafe paths, unsupported overrides and invalid headers are rejected before IO',
    () async {
      var calls = 0;
      final importer = ClashSubscriptionImporter(
        resolve: (_) async {
          calls++;
          return _payload('Remote');
        },
      );
      for (final provider in [
        {'type': 'file', 'path': '../private'},
        {'type': 'file', 'path': r'C:\private'},
        {
          ..._http(),
          'override': {'udp': true},
        },
        {..._http(), 'filter': '.*'},
        {
          ..._http(),
          'header': {
            'Authorization': ['a\r\nb'],
          },
        },
        {
          ..._http(),
          'payload': [_node('Fallback')],
        },
      ]) {
        expect(
          (await importer.import(_source({'remote': provider}))).profile,
          isNull,
        );
      }
      expect(calls, 0);
    },
  );

  test(
    'health-check losses are warnings and url-test inherits its URL',
    () async {
      final importer = ClashSubscriptionImporter(
        resolve: (_) async => _payload('Remote'),
      );
      final result = await importer.import(
        _source(
          {
            'remote': {
              ..._http(),
              'path': './cache.yaml',
              'health-check': {
                'enable': true,
                'url': 'https://probe.invalid/check',
                'interval': 300,
              },
            },
          },
          groups: [
            {
              'name': 'Selected',
              'type': 'url-test',
              'use': ['remote'],
            },
          ],
        ),
      );
      expect(
        result.profile!.selectors.single.testUrl,
        'https://probe.invalid/check',
      );
      expect(
        result.issues.map((issue) => issue.code),
        containsAll([
          'provider_cache_path_client_owned',
          'provider_health_check_not_migrated',
        ]),
      );
      expect(
        result.issues.every(
          (issue) => issue.severity == CoreConfigIssueSeverity.warning,
        ),
        isTrue,
      );
    },
  );

  test('does not silently lose DNS or provider group filters', () async {
    final importer = ClashSubscriptionImporter(
      resolve: (_) async => _payload('Remote'),
    );
    final dns = await importer.import(
      _source(
        {'remote': _http()},
        extra: {
          'dns': {'enable': true},
        },
      ),
    );
    expect(dns.profile, isNull);
    expect(
      dns.issues.map((issue) => issue.code),
      contains('dns_conversion_required'),
    );
    final filter = await importer.import(
      _source(
        {'remote': _http()},
        groups: [
          {
            'name': 'Selected',
            'type': 'select',
            'use': ['remote'],
            'filter': 'Japan',
          },
        ],
      ),
    );
    expect(filter.profile, isNull);
    expect(
      filter.issues.map((issue) => issue.code),
      contains('unsupported_field'),
    );
  });

  test('same-name nodes never silently overwrite across providers', () async {
    final importer = ClashSubscriptionImporter(
      resolve: (_) async => _payload('Duplicate'),
    );
    final result = await importer.import(
      _source({'first': _http('a'), 'second': _http('b')}),
    );
    expect(result.profile, isNull);
    expect(
      result.issues.map((issue) => issue.code),
      contains('duplicate_node_tag'),
    );
  });

  test('unknown and empty providers never become DIRECT fallbacks', () async {
    final importer = ClashSubscriptionImporter(
      resolve: (_) async => 'proxies: []',
    );
    final empty = await importer.import(_source({'remote': _http()}));
    expect(empty.profile, isNull);
    expect(empty.issues.map((issue) => issue.code), contains('empty_provider'));
    final unknown = await importer.import(
      _source(
        {},
        groups: [
          {
            'name': 'Selected',
            'type': 'select',
            'use': ['missing'],
          },
        ],
      ),
    );
    expect(unknown.profile, isNull);
    expect(
      unknown.issues.map((issue) => issue.code),
      contains('unknown_provider_reference'),
    );
  });

  test('node conversion errors retain their provider origin', () async {
    final importer = ClashSubscriptionImporter(
      resolve: (_) async => jsonEncode({
        'proxies': [
          {'name': 'Unsupported', 'type': 'ssr'},
        ],
      }),
    );
    final result = await importer.import(_source({'remote': _http()}));
    expect(result.profile, isNull);
    final issue = result.issues.singleWhere(
      (issue) => issue.code == 'unsupported_protocol',
    );
    expect(issue.path, 'proxy-providers.0.payload.0.type');
  });

  test(
    'partial failures expose no partial profile or resolver exception secrets',
    () async {
      final importer = ClashSubscriptionImporter(
        resolve: (request) async {
          if (request.name == 'broken') {
            throw StateError('https://private.invalid/token-secret');
          }
          return _payload('Good');
        },
      );
      final result = await importer.import(
        _source({'good': _http(), 'broken': _http()}),
      );
      expect(result.profile, isNull);
      expect(
        result.issues.map((issue) => issue.code),
        contains('provider_resolution_failed'),
      );
      expect(
        result.issues.any((issue) => issue.path.contains('token-secret')),
        isFalse,
      );
    },
  );

  test(
    'bounds concurrent resolution and aborts new work after timeout',
    () async {
      var active = 0;
      var maximum = 0;
      final importer = ClashSubscriptionImporter(
        concurrency: 2,
        resolve: (request) async {
          active++;
          if (active > maximum) maximum = active;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          active--;
          return _payload(request.name);
        },
      );
      final result = await importer.import(
        _source({for (var i = 0; i < 8; i++) 'p$i': _http('$i')}),
      );
      expect(result.profile, isNotNull);
      expect(maximum, 2);
      var calls = 0;
      final blocked = ClashSubscriptionImporter(
        concurrency: 2,
        timeout: const Duration(milliseconds: 10),
        resolve: (_) {
          calls++;
          return Completer<String>().future;
        },
      );
      expect(
        (await blocked.import(
          _source({for (var i = 0; i < 8; i++) 'p$i': _http('$i')}),
        )).profile,
        isNull,
      );
      expect(calls, 2);
    },
  );

  test(
    'enforces per-provider limits and rejects full configs masquerading as payloads',
    () async {
      final importer = ClashSubscriptionImporter(
        resolve: (_) async => _payload('Large'),
      );
      final limited = await importer.import(
        _source({
          'remote': {..._http(), 'size-limit': 5},
        }),
      );
      expect(limited.profile, isNull);
      expect(
        limited.issues.map((issue) => issue.code),
        contains('provider_payload_too_large'),
      );
      final unexpected = ClashSubscriptionImporter(
        resolve: (_) async => jsonEncode({
          'proxies': [_node('Remote')],
          'rules': ['MATCH,DIRECT'],
        }),
      );
      final result = await unexpected.import(_source({'remote': _http()}));
      expect(result.profile, isNull);
      expect(
        result.issues.map((issue) => issue.code),
        contains('unexpected_provider_payload_fields'),
      );
    },
  );

  test('aggregate payloads are bounded before any payload expansion', () async {
    final content = '#${'x' * (9 * 1024 * 1024)}\nproxies: []';
    final importer = ClashSubscriptionImporter(resolve: (_) async => content);
    final result = await importer.import(
      _source({for (var i = 0; i < 4; i++) 'p$i': _http('$i')}),
    );
    expect(result.profile, isNull);
    expect(
      result.issues.map((issue) => issue.code),
      contains('provider_total_size_exceeded'),
    );
  });

  test(
    'caps group fan-out instead of multiplying a small input without bound',
    () async {
      final importer = ClashSubscriptionImporter(
        resolve: (_) => throw StateError('Inline only'),
      );
      final result = await importer.import(
        _source(
          {
            'remote': {
              'type': 'inline',
              'payload': [for (var i = 0; i < 1000; i++) _node('n$i')],
            },
          },
          groups: [
            for (var i = 0; i < 251; i++)
              {
                'name': i == 0 ? 'Selected' : 'g$i',
                'type': 'select',
                'include-all-providers': true,
              },
          ],
        ),
      );
      expect(result.profile, isNull);
      expect(
        result.issues.map((issue) => issue.code),
        contains('expanded_membership_limit_exceeded'),
      );
    },
  );

  test('duplicate references collapse with a visible warning', () async {
    final importer = ClashSubscriptionImporter(
      resolve: (_) async => _payload('Remote'),
    );
    final result = await importer.import(
      _source(
        {'remote': _http()},
        groups: [
          {
            'name': 'Selected',
            'type': 'select',
            'proxies': ['Remote'],
            'use': ['remote', 'remote'],
          },
        ],
      ),
    );
    expect(result.profile!.selectors.single.members, ['Remote']);
    expect(result.issues.single.code, 'duplicate_group_member_collapsed');
  });

  test(
    'invalid source/URL and refreshing a broken payload produce no replacement',
    () async {
      var payload = _payload('Remote');
      final importer = ClashSubscriptionImporter(resolve: (_) async => payload);
      final source = _source({'remote': _http()});
      final initial = await importer.import(source);
      expect(initial.profile!.nodes.single.tag, 'Remote');
      payload = 'proxies: invalid';
      expect((await importer.import(source)).profile, isNull);
      expect(initial.profile!.nodes.single.tag, 'Remote');
      expect(
        (await importer.import('proxy-providers: [')).issues.single.code,
        'invalid_yaml',
      );
      expect(
        (await importer.import(
          _source({
            'remote': {..._http(), 'url': 'file:///private'},
          }),
        )).profile,
        isNull,
      );
    },
  );
}
