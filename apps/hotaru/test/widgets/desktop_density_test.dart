import 'package:hotaru/ui/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_app.dart';

void main() {
  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    testWidgets('$platform keeps its own app bar height and readable title', (
      tester,
    ) async {
      final desktop = platform == TargetPlatform.windows;
      await tester.pumpWidget(
        TestApp(
          wrapInProviderScope: true,
          theme: ThemeData(platform: platform).withAppTypography,
          child: const CommonScaffold(
            title: 'Dashboard',
            body: SizedBox.expand(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final bar = tester.widget<AppBar>(find.byType(AppBar));
      expect(tester.getSize(find.byType(AppBar)).height, desktop ? 56 : 72);
      expect(bar.titleTextStyle?.fontSize, desktop ? 20 : 24);
      final context = tester.element(find.byType(CommonScaffold));
      expect(AppTextStyle.body.of(context).fontSize, desktop ? 15 : 17);
      expect(
        Theme.of(context).textTheme.bodyLarge?.fontSize,
        desktop ? 15 : 17,
      );
      tester.platformDispatcher.textScaleFactorTestValue = 1.4;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pump();
      expect(
        MediaQuery.textScalerOf(
          tester.element(find.byType(CommonScaffold)),
        ).scale(10),
        14,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
