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

  test('genColorScheme applies separate system light and dark seeds', () {
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
      hotaruColorScheme(Brightness.light, accent: const Color(0xFF00FF00)),
    );
    expect(
      container.read(genColorSchemeProvider(Brightness.dark)),
      hotaruColorScheme(Brightness.dark, accent: const Color(0xFF0000FF)),
    );
  });

  test('pure black darkens the dark canvas and preserves the light theme', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final light = container.read(genColorSchemeProvider(Brightness.light));
    final dark = container.read(genColorSchemeProvider(Brightness.dark));
    container
        .read(themeSettingProvider.notifier)
        .update((state) => state.copyWith(pureBlack: true));

    expect(container.read(genColorSchemeProvider(Brightness.light)), light);
    final black = container.read(genColorSchemeProvider(Brightness.dark));
    expect(black.surface, Colors.black);
    expect(black.primary, dark.primary);
  });

  test(
    'genColorScheme uses the accent when system brightness seeds are absent',
    () {
      const accent = Color(0xFFFF0000);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container
          .read(dynamicColorProvider.notifier)
          .seed(lightSeed: null, darkSeed: null, accentColor: accent);

      expect(
        container.read(genColorSchemeProvider(Brightness.light)),
        hotaruColorScheme(Brightness.light, accent: accent),
      );
    },
  );
}
