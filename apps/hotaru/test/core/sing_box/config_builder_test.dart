import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/config/profile.dart';
import 'package:hotaru/core/sing_box/config_builder.dart';

void main() {
  final builder = SingBoxConfigBuilder();
  const listeners = CoreListenerSpec(
    mixedPort: 17890,
    controllerPort: 19090,
    secret: 'fixture-secret',
  );
  const direct = CoreNodeSpec(tag: 'direct', protocol: CoreNodeProtocol.direct);

  test(
    'compiles owned profile IR without exposing listeners on the LAN',
    () async {
      final result = await builder.build(
        CoreProfileSpec(
          nodes: [
            direct,
            const CoreNodeSpec(
              tag: 'proxy',
              protocol: CoreNodeProtocol.socks,
              server: '127.0.0.1',
              port: 1080,
            ),
          ],
          selectors: [
            CoreSelectorSpec(
              tag: 'selected',
              members: ['direct', 'proxy'],
              selected: 'proxy',
            ),
          ],
          finalOutbound: 'selected',
        ),
        listeners,
      );
      expect(result.issues, isEmpty);
      final config = jsonDecode(result.json!) as Map<String, dynamic>;
      expect(config['inbounds'].single['listen'], '127.0.0.1');
      expect(config['outbounds'].last['default'], 'proxy');
      expect(config['route']['final'], 'selected');
      expect(
        config['experimental']['clash_api']['external_controller'],
        '127.0.0.1:19090',
      );
    },
  );

  test(
    'rejects duplicate tags and unknown references instead of dropping them',
    () async {
      final result = await builder.build(
        CoreProfileSpec(
          nodes: [direct, direct],
          selectors: [
            CoreSelectorSpec(tag: 'selected', members: ['missing']),
          ],
          finalOutbound: 'missing-final',
        ),
        listeners,
      );
      expect(result.json, isNull);
      expect(
        result.issues.map((issue) => issue.code),
        containsAll([
          'invalid_or_duplicate_tag',
          'unknown_member',
          'unknown_final_outbound',
        ]),
      );
    },
  );

  test('rejects cycles through nested selectors', () async {
    final result = await builder.build(
      CoreProfileSpec(
        nodes: [direct],
        selectors: [
          CoreSelectorSpec(tag: 'a', members: ['b', 'direct']),
          CoreSelectorSpec(tag: 'b', members: ['a']),
        ],
        finalOutbound: 'a',
      ),
      listeners,
    );
    expect(result.json, isNull);
    expect(result.issues.single.code, 'selector_cycle');
  });

  test(
    'handles deeply nested selectors without recursive stack growth',
    () async {
      final result = await builder.build(
        CoreProfileSpec(
          nodes: [direct],
          selectors: [
            for (var index = 0; index < 5000; index++)
              CoreSelectorSpec(
                tag: 'group-$index',
                members: [index == 4999 ? 'direct' : 'group-${index + 1}'],
              ),
          ],
          finalOutbound: 'group-0',
        ),
        listeners,
      );
      expect(result.json, isNotNull);
      expect(result.issues, isEmpty);
    },
  );

  test(
    'rejects overlapping listeners and empty controller credentials',
    () async {
      final result = await builder.build(
        CoreProfileSpec(
          nodes: [direct],
          selectors: [],
          finalOutbound: 'direct',
        ),
        const CoreListenerSpec(
          mixedPort: 19090,
          controllerPort: 19090,
          secret: '',
        ),
      );
      expect(result.json, isNull);
      expect(
        result.issues.map((issue) => issue.code),
        containsAll(['invalid_listener_ports', 'invalid_controller_secret']),
      );
    },
  );

  test('does not silently discard proxy fields or half credentials', () async {
    final result = await builder.build(
      CoreProfileSpec(
        nodes: [
          const CoreNodeSpec(
            tag: 'direct',
            protocol: CoreNodeProtocol.direct,
            port: 1234,
          ),
          const CoreNodeSpec(
            tag: 'proxy',
            protocol: CoreNodeProtocol.http,
            server: '',
            port: 0,
            username: 'u',
          ),
        ],
        selectors: [],
        finalOutbound: 'direct',
      ),
      listeners,
    );
    expect(result.json, isNull);
    expect(
      result.issues.map((issue) => issue.code),
      containsAll([
        'direct_has_proxy_fields',
        'invalid_server',
        'incomplete_credentials',
      ]),
    );
  });
}
