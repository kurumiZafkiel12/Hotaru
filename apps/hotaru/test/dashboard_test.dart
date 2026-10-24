import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/dashboard.dart';

void main() {
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
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(file.readAsStringSync(), '[1,2,3]');
    await tester.tap(find.text('工具箱'));
    await tester.pumpAndSettle();
    expect(find.text('网络工具箱'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    dir.deleteSync(recursive: true);
  });
}
