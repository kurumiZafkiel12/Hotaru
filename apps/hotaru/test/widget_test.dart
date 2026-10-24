import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/main.dart';

void main() {
  testWidgets('diagnostic UI never claims network connected', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: CorePage()));
    expect(find.text('验证并启动诊断内核'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.textContaining('不启用系统代理'), findsOneWidget);
  });
}
