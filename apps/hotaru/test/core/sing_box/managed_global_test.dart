import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/config/clash_importer.dart';
import 'package:hotaru/core/config/mode_outbounds.dart';
import 'package:hotaru/core/config/profile.dart';
import 'package:hotaru/core/config/route_preview.dart';
import 'package:hotaru/core/sing_box/config_builder.dart';

void main() {
  Future<CoreProfileSpec> source(
    List<String> rules, {
    String first = 'A',
  }) async {
    final result = await ClashProfileImporter().import(
      jsonEncode({
        'proxies': [
          for (final name in [first, 'B'])
            {'name': name, 'type': 'http', 'server': '127.0.0.1', 'port': 8080},
        ],
        'rules': rules,
      }),
    );
    expect(result.issues, isEmpty);
    return result.profile!;
  }

  test(
    'implicit GLOBAL is a managed action with no artificial source node',
    () async {
      final profile = await source(['DOMAIN,example.com,GLOBAL', 'MATCH,A']);
      expect(profile.rules.single.action, CoreRuleAction.global);
      expect(profile.rules.single.outbound, isNull);
      expect(profile.nodes.map((node) => node.tag), ['A', 'B']);
      final global = CoreModeOutbounds(profile).global.tag;
      final preview = await CoreRoutePreviewer().preview(
        profile,
        'example.com',
        selections: {global: 'B'},
      );
      expect(preview.status, CoreRoutePreviewStatus.resolved);
      expect(preview.chain, [global, 'B']);
      expect(preview.selectedOutbounds, {global: 'B'});
      final fallback = await CoreRoutePreviewer().preview(
        profile,
        'other.example',
      );
      expect(fallback.chain, ['A']);
      final built = await SingBoxConfigBuilder().build(
        profile,
        const CoreListenerSpec(
          mixedPort: 17890,
          controllerPort: 19090,
          secret: 'fixture',
        ),
      );
      expect(built.issues, isEmpty);
      final rules = jsonDecode(built.json!)['route']['rules'] as List;
      expect(rules.where((rule) => rule['domain'] != null).single, {
        'domain': ['example.com'],
        'action': 'route',
        'outbound': global,
      });
    },
  );

  test(
    'MATCH GLOBAL uses a finite source seed and follows actual managed selection',
    () async {
      final profile = await source(['MATCH,GLOBAL']);
      expect(profile.finalOutbound, 'A');
      expect(profile.rules.single.action, CoreRuleAction.global);
      final global = CoreModeOutbounds(profile).global;
      expect(global.selected, 'A');
      expect(global.members, ['A', 'B']);
      final unknown = await CoreRoutePreviewer().preview(
        profile,
        'example.com',
      );
      expect(unknown.status, CoreRoutePreviewStatus.selectionRequired);
      for (final selected in ['A', 'B']) {
        final preview = await CoreRoutePreviewer().preview(
          profile,
          'example.com',
          selections: {global.tag: selected},
        );
        expect(preview.chain, [global.tag, selected]);
      }
    },
  );

  test('explicit source GLOBAL retains its own routing identity', () async {
    final profile = await source(['MATCH,GLOBAL'], first: 'GLOBAL');
    expect(profile.rules, isEmpty);
    expect(profile.finalOutbound, 'GLOBAL');
    final preview = await CoreRoutePreviewer().preview(profile, 'example.com');
    expect(preview.chain, ['GLOBAL']);
  });

  test(
    'generated global tag avoids collisions with a source Hotaru GLOBAL',
    () async {
      final profile = await source(['MATCH,GLOBAL'], first: 'Hotaru GLOBAL');
      final modes = CoreModeOutbounds(profile);
      expect(modes.global.tag, 'Hotaru GLOBAL (1)');
      final preview = await CoreRoutePreviewer().preview(
        profile,
        'example.com',
        selections: {modes.global.tag: 'B'},
      );
      expect(preview.chain, ['Hotaru GLOBAL (1)', 'B']);
    },
  );

  test(
    'empty GLOBAL-only source receives a real DIRECT seed without a cycle',
    () async {
      final result = await ClashProfileImporter().import(
        '{"rules":["MATCH,GLOBAL"]}',
      );
      expect(result.issues, isEmpty);
      final profile = result.profile!;
      expect(profile.finalOutbound, 'DIRECT');
      final global = CoreModeOutbounds(profile).global.tag;
      final preview = await CoreRoutePreviewer().preview(
        profile,
        'example.com',
        selections: {global: 'DIRECT'},
      );
      expect(preview.chain, [global, 'DIRECT']);
    },
  );
}
