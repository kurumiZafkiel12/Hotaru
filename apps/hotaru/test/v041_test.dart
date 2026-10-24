import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/profiles/importer.dart';
import 'package:hotaru/profiles/profile_store.dart';
import 'package:hotaru/profiles/overrides.dart';
import 'package:hotaru/core/proxy_config.dart';
import 'package:hotaru/platform/app_updater.dart';

void main() {
  const providerConfig = '''
proxy-providers:
  remote:
    type: http
    url: https://example.com/nodes.yaml
    interval: 3600
proxy-groups:
  - {name: 手动, type: select, use: [remote]}
  - {name: 自动, type: url-test, use: [remote], url: https://example.com, interval: 300}
  - {name: 故障, type: fallback, use: [remote], url: https://example.com, interval: 300}
  - {name: 均衡, type: load-balance, use: [remote], url: https://example.com, interval: 300}
rule-providers:
  local: {type: http, behavior: classical, url: https://example.com/rules.yaml, interval: 3600}
rules: ["RULE-SET,local,DIRECT", "MATCH,手动"]
''';
  test('provider-only import preserves all four groups and remote rules', () {
    final parsed = ProfileImporter.parse(providerConfig, ImportMode.fullConfig);
    expect(parsed.nodeCount, 0);
    final built = ProxyConfigBuilder.build(
      profileConfig: parsed.config,
      mode: ImportMode.fullConfig,
      selectedNode: '',
    );
    expect(built, parsed.config);
    expect((built['proxy-groups'] as List).length, 4);
    expect(
      () => ProfileImporter.parse(providerConfig, ImportMode.nodesOnly),
      throwsFormatException,
    );
  });
  test(
    'full config accepts native node fields and URI-only generates routing',
    () {
      final parsed = ProfileImporter.parse(
        'proxies: [{name: direct, type: direct}]\nrules: [MATCH,direct]',
        ImportMode.fullConfig,
      );
      expect(parsed.nodeCount, 1);
      final uri = ProfileImporter.parse(
        'socks5://localhost:1080#test',
        ImportMode.fullConfig,
      );
      final built = ProxyConfigBuilder.build(
        profileConfig: uri.config,
        mode: ImportMode.fullConfig,
        selectedNode: 'test',
      );
      expect(built['rules'], ['MATCH,HOTARU']);
    },
  );
  test(
    'provider-only profiles reopen and updates preserve independent overlays',
    () async {
      final dir = await Directory.systemTemp.createTemp('hotaru-v041-store-');
      try {
        final store = ProfileStore(File('${dir.path}/profiles.json'));
        final config = ProfileImporter.parse(
          providerConfig,
          ImportMode.fullConfig,
        ).config;
        final profile = await store.add(
          name: 'providers',
          mode: ImportMode.fullConfig,
          source: 'url',
          sourceUrl: 'https://example.com/sub',
          userInfo: 'total=1024;expire=12345',
          config: config,
        );
        await store.replace(
          StoredProfile.fromJson({
            ...profile.toJson(),
            'merge': {
              'dns': {'enable': true},
            },
            'script': 'function main(c){return c;}',
          }),
        );
        final loaded = await ProfileStore.load(store.file);
        expect(loaded.loadWarning, false);
        expect(loaded.selectedProfile?.id, profile.id);
        expect(loaded.selectedProfile?.merge, {
          'dns': {'enable': true},
        });
        expect(loaded.selectedProfile?.sourceUrl, 'https://example.com/sub');
        expect(loaded.selectedProfile?.userInfo, 'total=1024;expire=12345');
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );
  test('Merge is recursive, lists replace, original remains intact', () async {
    final original = {
      'dns': {'enable': true, 'ipv6': false},
      'rules': ['MATCH,DIRECT'],
    };
    final snapshot = jsonEncode(original);
    final result = await ProfileOverrides.apply(
      original,
      ProfileOverrides.parseMerge('dns: {ipv6: true}\nrules: ["MATCH,REJECT"]'),
      '',
    );
    expect(result, {
      'dns': {'enable': true, 'ipv6': true},
      'rules': ['MATCH,REJECT'],
    });
    expect(jsonEncode(original), snapshot);
    expect(() => ProfileOverrides.parseMerge('[1, 2]'), throwsFormatException);
  });
  test('update versions compare numeric preview sequence', () {
    expect(AppUpdater.newer('v0.4.1-preview.11', 'v0.4.1-preview.9'), true);
    expect(AppUpdater.newer('v0.4.0-preview.99', 'v0.4.1-preview.1'), false);
    expect(AppUpdater.newer('v0.4.1-preview.2', 'v0.4.1-preview.2'), false);
    expect(AppUpdater.newer('v0.4.1', 'v0.4.1-preview.99'), true);
    expect(AppUpdater.newer('v0.4.1-preview.100', 'v0.4.1'), false);
  });
  test(
    'node-only routing is generated before overrides, never after',
    () async {
      final source = {
        'proxies': [
          {'name': 'a', 'type': 'direct'},
        ],
      };
      final result = await ProfileOverrides.buildRuntime(
        source: source,
        mode: ImportMode.nodesOnly,
        selectedNode: 'a',
        overlay: {
          'mode': 'global',
          'rules': ['MATCH,REJECT'],
          'dns': {'ipv6': true},
        },
      );
      expect(result['mode'], 'global');
      expect(result['rules'], ['MATCH,REJECT']);
      expect(result['dns']['enable'], true);
      expect(result['dns']['ipv6'], true);
      expect((result['proxy-groups'] as List).first['name'], 'HOTARU');
      expect(source.containsKey('rules'), false);
    },
  );
}
