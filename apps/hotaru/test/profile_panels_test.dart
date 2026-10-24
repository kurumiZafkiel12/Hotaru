import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/profiles/importer.dart';
import 'package:hotaru/profiles/profile_store.dart';
import 'package:hotaru/profiles/profiles_page.dart';

void main() {
  testWidgets(
    'configuration owns import inputs; nodes own the saved node list',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final dir = Directory.systemTemp.createTempSync('hotaru-panels-');
      final file = File('${dir.path}/profiles.json');
      await tester.runAsync(() async {
        final store = ProfileStore(file);
        await store.add(
          name: '订阅一',
          mode: ImportMode.fullConfig,
          source: 'paste',
          config: {
            'proxies': [
              {
                'name': '节点甲',
                'type': 'socks5',
                'server': 'localhost',
                'port': 1080,
              },
            ],
          },
        );
      });
      const key = ValueKey('persistent-profile-page');
      await tester.pumpWidget(
        MaterialApp(
          home: ProfilesPage(key: key, panel: 'nodes', storeFile: file),
        ),
      );
      for (var i = 0; i < 60; i++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        await tester.pump();
        if (tester.any(find.text('节点甲'))) break;
      }
      expect(find.text('节点甲'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'HTTPS 订阅地址'), findsNothing);
      expect(find.text('添加配置'), findsNothing);
      final state = tester.state(find.byType(ProfilesPage));
      await tester.pumpWidget(
        MaterialApp(
          home: ProfilesPage(key: key, panel: 'config', storeFile: file),
        ),
      );
      await tester.pumpAndSettle();
      expect(identical(state, tester.state(find.byType(ProfilesPage))), true);
      await tester.tap(find.text('添加配置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('链接'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'HTTPS 订阅地址'), findsOneWidget);
      expect(find.text('节点甲'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      dir.deleteSync(recursive: true);
    },
  );
}
