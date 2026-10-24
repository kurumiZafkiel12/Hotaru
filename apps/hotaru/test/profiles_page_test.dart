import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/profiles/profiles_page.dart';

void main() {
  testWidgets('import saves a profile, selection persists, delete clears', (
    tester,
  ) async {
    // The page is one long ListView; give the test a tall viewport so all
    // sections are built without scrolling.
    tester.view.physicalSize = const Size(1000, 3400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final dir = Directory.systemTemp.createTempSync('hotaru-page-');
    final file = File('${dir.path}/profiles.json');
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(home: ProfilesPage(storeFile: file)));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.text('还没有保存的订阅。导入后，节点会列在这里供选择。'), findsOneWidget);

    await tester.enterText(
      find.byType(TextField).at(1),
      'socks5://127.0.0.1:1080#node-one\nss://aes-128-gcm:pw@example.com:8388#node-two',
    );
    await tester.runAsync(() async {
      await tester.tap(find.text('检查并保存'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('已保存'), findsOneWidget);
    expect(find.text('node-one'), findsOneWidget);
    expect(find.text('node-two'), findsOneWidget);
    expect(file.existsSync(), isTrue);
    expect(file.readAsStringSync(), contains('node-two'));

    // Switch selection to the second node; it must be the persisted one.
    await tester.runAsync(() async {
      await tester.tap(find.text('node-two'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(file.readAsStringSync(), contains('"selectedNode":"node-two"'));

    // Reopen the page on the same file: selection and nodes are still there.
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(home: ProfilesPage(storeFile: file)));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.text('node-one'), findsOneWidget);
    expect(find.text('node-two'), findsOneWidget);

    // Broken import must not destroy the saved profile.
    await tester.enterText(find.byType(TextField).at(1), 'not-a-config');
    await tester.runAsync(() async {
      await tester.tap(find.text('检查并保存'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('导入失败'), findsOneWidget);
    expect(find.text('node-two'), findsOneWidget);

    // Delete removes the profile and its nodes.
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('删除node-one'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(find.text('node-two'), findsNothing);
    expect(find.text('还没有保存的订阅。导入后，节点会列在这里供选择。'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    dir.deleteSync(recursive: true);
  });
}
