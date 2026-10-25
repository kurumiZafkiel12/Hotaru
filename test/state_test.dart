import 'package:hotaru/common/constant.dart';
import 'package:hotaru/providers/providers.dart';
import 'package:hotaru/ui/color.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'DynamicColor falls back to the default primary color before seeding',
    () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(
        container.read(dynamicColorProvider).accentColor,
        const Color(defaultPrimaryColor),
      );
    },
  );

  test('genColorScheme returns the fixed palette regardless of seeds', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(dynamicColorProvider.notifier)
        .seed(
          lightSeed: const Color(0xFF00FF00),
          darkSeed: const Color(0xFF0000FF),
          accentColor: const Color(defaultPrimaryColor),
        );

    expect(
      container.read(genColorSchemeProvider(Brightness.light)),
      hotaruColorScheme(Brightness.light),
    );
    expect(
      container.read(genColorSchemeProvider(Brightness.dark)),
      hotaruColorScheme(Brightness.dark),
    );
  });

  test('pure black leaves both schemes unchanged under the fixed palette', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final light = container.read(genColorSchemeProvider(Brightness.light));
    final dark = container.read(genColorSchemeProvider(Brightness.dark));
    container
        .read(themeSettingProvider.notifier)
        .update((state) => state.copyWith(pureBlack: true));

    expect(container.read(genColorSchemeProvider(Brightness.light)), light);
    expect(container.read(genColorSchemeProvider(Brightness.dark)), dark);
  });

  test(
    'genColorScheme ignores the accent seed and returns the fixed palette',
    () {
      const accent = Color(0xFFFF0000);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container
          .read(dynamicColorProvider.notifier)
          .seed(lightSeed: null, darkSeed: null, accentColor: accent);

      expect(
        container.read(genColorSchemeProvider(Brightness.light)),
        hotaruColorScheme(Brightness.light),
      );
    },
  );
}
