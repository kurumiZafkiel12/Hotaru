import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/profiles/importer.dart';
import 'package:hotaru/profiles/profile_store.dart';

void main() {
  const config = {
    'proxies': [
      {'name': 'n1', 'type': 'socks5', 'server': '127.0.0.1', 'port': 1080},
      {'name': 'n2', 'type': 'ss', 'server': 'example.com', 'port': 8388},
    ],
  };

  test('add, select, reload and remove persist atomically', () async {
    final dir = await Directory.systemTemp.createTemp('hotaru-store-');
    final file = File('${dir.path}/profiles.json');
    try {
      var store = await ProfileStore.load(file);
      expect(store.profiles, isEmpty);
      final p = await store.add(
        name: '测试订阅',
        mode: ImportMode.nodesOnly,
        source: 'paste',
        config: config,
      );
      expect(store.selectedNode, 'n1');
      expect(File('${file.path}.tmp').existsSync(), isFalse);
      await store.select(p.id, 'n2');

      store = await ProfileStore.load(file);
      expect(store.profiles.single.name, '测试订阅');
      expect(store.selectedProfileId, p.id);
      expect(store.selectedNode, 'n2');
      expect(store.selectedProfile!.nodes.length, 2);

      await store.remove(p.id);
      store = await ProfileStore.load(file);
      expect(store.profiles, isEmpty);
      expect(store.selectedNode, isNull);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('corrupt store loads empty with warning and keeps old file', () async {
    final dir = await Directory.systemTemp.createTemp('hotaru-store-');
    final file = File('${dir.path}/profiles.json')
      ..writeAsStringSync(jsonEncode({'version': 99}));
    try {
      final store = await ProfileStore.load(file);
      expect(store.profiles, isEmpty);
      expect(store.loadWarning, isTrue);
      // Not overwritten until an explicit save happens.
      expect(file.readAsStringSync(), jsonEncode({'version': 99}));
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
