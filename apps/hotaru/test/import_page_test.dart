import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/profiles/import_page.dart';

void main() {
  testWidgets(
    'import preview reports node count without claiming connectivity',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: ImportPage()));
      await tester.enterText(
        find.byType(TextField).first,
        'socks5://localhost:1080#test',
      );
      await tester.tap(find.text('检查粘贴内容'));
      await tester.pumpAndSettle();
      expect(find.textContaining('1 个节点'), findsOneWidget);
      expect(find.textContaining('不代表节点可连接'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, 'broken');
      await tester.tap(find.text('检查粘贴内容'));
      await tester.pumpAndSettle();
      expect(find.textContaining('导入失败'), findsOneWidget);
      expect(find.textContaining('1 个节点'), findsNothing);
    },
  );
}
