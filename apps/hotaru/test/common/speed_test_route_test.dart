import 'package:hotaru/common/speed_test_route.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('injectSpeedTestRoute', () {
    test('adds reserved group with all proxies, groups and DIRECT', () {
      final config = <String, dynamic>{
        'proxies': [
          {'name': 'NodeA', 'type': 'vless'},
          {'name': 'NodeB', 'type': 'hysteria2'},
        ],
        'proxy-groups': [
          {
            'name': 'Main',
            'type': 'select',
            'proxies': ['NodeA', 'NodeB'],
            'use': ['provider-1'],
          },
          {
            'name': 'Sub',
            'type': 'select',
            'proxies': ['NodeB'],
          },
        ],
      };
      final name = injectSpeedTestRoute(config);
      expect(name, speedTestGroupBaseName);
      final groups = config['proxy-groups'] as List;
      expect(groups.length, 3);
      final reserved = groups.last as Map;
      expect(reserved['type'], 'select');
      expect(reserved['proxies'], ['NodeA', 'NodeB', 'Main', 'Sub', 'DIRECT']);
      expect(reserved['use'], ['provider-1']);
      final listeners = config['listeners'] as List;
      expect(listeners.length, 1);
      final listener = listeners.single as Map;
      expect(listener['name'], speedTestListenerName);
      expect(listener['listen'], '127.0.0.1');
      expect(listener['port'], speedTestPort);
      expect(listener['proxy'], speedTestGroupBaseName);
      expect(listener['users'], isEmpty);
    });

    test(
      'the loopback test listener does not inherit profile authentication',
      () {
        final config = <String, dynamic>{
          'authentication': ['lan-user:test-password'],
          'proxies': [
            {'name': 'NodeA', 'type': 'http'},
          ],
          'listeners': [
            {
              'name': 'private',
              'type': 'mixed',
              'port': 7890,
              'users': [
                {'username': 'u', 'password': 'p'},
              ],
            },
          ],
        };
        injectSpeedTestRoute(config);
        expect(config['authentication'], ['lan-user:test-password']);
        final listeners = config['listeners'] as List;
        expect((listeners.first as Map)['users'], [
          {'username': 'u', 'password': 'p'},
        ]);
        final internal = listeners.last as Map;
        expect(internal['listen'], '127.0.0.1');
        expect(internal['users'], isEmpty);
      },
    );

    test('preserves existing listeners and avoids name collisions', () {
      final config = <String, dynamic>{
        'proxies': [
          {'name': speedTestGroupBaseName, 'type': 'socks5'},
        ],
        'listeners': [
          {'name': 'mine', 'type': 'mixed', 'port': 7890},
        ],
      };
      final name = injectSpeedTestRoute(config);
      expect(name, '$speedTestGroupBaseName-2');
      final listeners = config['listeners'] as List;
      expect(listeners.length, 2);
      expect((listeners.last as Map)['proxy'], name);
      final groups = config['proxy-groups'] as List;
      final reserved = groups.single as Map;
      expect(reserved['proxies'], [speedTestGroupBaseName, 'DIRECT']);
    });

    test(
      'provider-only include-all profiles get a usable dedicated speed group',
      () {
        final config = <String, dynamic>{
          'proxy-providers': {
            'subscription': {
              'type': 'http',
              'url': 'https://example.test/nodes.yaml',
            },
          },
          'proxy-groups': [
            {'name': 'Select', 'type': 'select', 'include-all': true},
          ],
        };
        expect(injectSpeedTestRoute(config), speedTestGroupBaseName);
        final reserved = (config['proxy-groups'] as List).last as Map;
        expect(reserved['use'], ['subscription']);
        expect(
          (config['listeners'] as List).single['proxy'],
          speedTestGroupBaseName,
        );
      },
    );

    test('skips injection when the profile has nothing testable', () {
      final config = <String, dynamic>{'proxies': [], 'proxy-groups': []};
      expect(injectSpeedTestRoute(config), '');
      expect(config.containsKey('listeners'), isFalse);
    });

    test('skips profiles whose groups only wrap built-in exits', () {
      final config = <String, dynamic>{
        'proxies': [],
        'proxy-groups': [
          {
            'name': 'Select',
            'type': 'select',
            'proxies': ['DIRECT'],
          },
        ],
      };
      expect(injectSpeedTestRoute(config), '');
      expect(config.containsKey('listeners'), isFalse);
      expect((config['proxy-groups'] as List), hasLength(1));
    });
  });

  group('resolveProxyChain', () {
    final proxies = <String, dynamic>{
      'NodeA': {'type': 'Vless'},
      'NodeB': {'type': 'Hysteria2'},
      'Sub': {'type': 'Selector', 'now': 'NodeB'},
      'Main': {'type': 'Selector', 'now': 'Sub'},
      'Loop': {'type': 'Selector', 'now': 'Loop'},
    };

    test('returns the node itself for a leaf proxy', () {
      expect(resolveProxyChain(proxies, 'NodeA'), ['NodeA']);
    });

    test('walks nested groups down to the leaf member', () {
      expect(resolveProxyChain(proxies, 'Main'), ['Main', 'Sub', 'NodeB']);
    });

    test('stops on selection cycles and unknown names', () {
      expect(resolveProxyChain(proxies, 'Loop'), ['Loop']);
      expect(resolveProxyChain(proxies, 'Missing'), ['Missing']);
    });
  });

  group('NodeSpeedTestGate', () {
    test('allows a single active test at a time', () {
      final first = NodeSpeedTestGate.tryAcquire();
      expect(first, isNotNull);
      expect(NodeSpeedTestGate.tryAcquire(), isNull);
      expect(NodeSpeedTestGate.isActive(first!), isTrue);
      NodeSpeedTestGate.release(first);
      expect(NodeSpeedTestGate.isActive(first), isFalse);
      final second = NodeSpeedTestGate.tryAcquire();
      expect(second, isNotNull);
      NodeSpeedTestGate.release(second!);
    });
  });
}
