import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/dashboard.dart';

void main() {
  test(
    'atomic layout write replaces content and leaves no temp file',
    () async {
      final dir = Directory.systemTemp.createTempSync('hotaru-atomic-test-');
      try {
        final file = File('${dir.path}/layout.json')
          ..writeAsStringSync('[0,1,2,3]');
        await writeLayoutAtomically(file, [3, 1]);
        expect(file.readAsStringSync(), '[3,1]');
        expect(File('${file.path}.tmp').existsSync(), isFalse);
        // A second write over the replaced file must also succeed (Windows
        // rename-over-existing is exercised by CI on windows-latest).
        await writeLayoutAtomically(file, [0]);
        expect(file.readAsStringSync(), '[0]');
        expect(File('${file.path}.tmp').existsSync(), isFalse);
      } finally {
        dir.deleteSync(recursive: true);
      }
    },
  );
  test('tryParseLayout rejects corrupt shapes and dedupes ids', () {
    expect(tryParseLayout([0, 2, 2, 1], 6), [0, 2, 1]);
    expect(tryParseLayout('nope', 6), isNull);
    expect(tryParseLayout([0, 99], 6), isNull);
    expect(tryParseLayout([0, 'a'], 6), isNull);
    expect(tryParseLayout(null, 6), isNull);
    expect(tryParseLayout([], 6), isEmpty);
  });
  testWidgets('corrupt layout file warns and falls back to defaults', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('hotaru-corrupt-test-');
    final file = File('${dir.path}/layout.json')..writeAsStringSync('###');
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Dashboard(diagnostic: const SizedBox(), storageFile: file),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(find.text('布局读取失败，已使用默认布局。'), findsOneWidget);
    expect(find.text('连接状态'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    dir.deleteSync(recursive: true);
  });
  testWidgets('layout changes persist and toolbox opens', (tester) async {
    final dir = Directory.systemTemp.createTempSync('hotaru-layout-test-');
    final file = File('${dir.path}/layout.json')
      ..writeAsStringSync('[0,1,2,3]');
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Dashboard(diagnostic: const SizedBox(), storageFile: file),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(find.text('一点微光，自在连接。'), findsOneWidget);
    await tester.tap(find.text('自定义'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('移除连接状态'));
      // Poll instead of a fixed sleep: slow CI runners need longer.
      for (var i = 0; i < 50 && file.readAsStringSync() != '[1,2,3]'; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    });
    await tester.pumpAndSettle();
    expect(file.readAsStringSync(), '[1,2,3]');
    await tester.tap(find.text('工具箱'));
    await tester.pumpAndSettle();
    expect(find.text('网络工具箱'), findsOneWidget);
    await tester.tap(find.text('节点'));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    final nodePage = tester.state(find.byType(Scaffold).last);
    await tester.tap(find.text('桌面'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('节点'));
    await tester.pumpAndSettle();
    expect(
      identical(nodePage, tester.state(find.byType(Scaffold).last)),
      isTrue,
    );
    await tester.pumpWidget(const SizedBox());
    dir.deleteSync(recursive: true);
  });
}
