import 'dart:math' as math;

import 'package:hotaru/ui/color.dart';
import 'package:hotaru/views/theme_dashboard_preview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_app.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
      'a $brightness preview remains readable inside the opposite theme',
      (tester) async {
        final colors = hotaruColorScheme(brightness);
        final outer = brightness == Brightness.dark
            ? Brightness.light
            : Brightness.dark;
        await tester.pumpWidget(
          TestApp(
            theme: ThemeData(colorScheme: hotaruColorScheme(outer)),
            child: ThemeDashboardPreview(
              colors: colors,
              navigation: const SizedBox(height: 48),
            ),
          ),
        );
        final text = tester.widget<Text>(find.text('192.0.2.10'));
        final foreground = text.style!.color!;
        expect(foreground, colors.onSurface);
        final light = math.max(
          foreground.computeLuminance(),
          colors.surface.computeLuminance(),
        );
        final dark = math.min(
          foreground.computeLuminance(),
          colors.surface.computeLuminance(),
        );
        expect((light + 0.05) / (dark + 0.05), greaterThan(4.5));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
