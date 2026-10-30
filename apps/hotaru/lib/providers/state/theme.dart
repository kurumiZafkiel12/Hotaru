part of '../state.dart';

typedef DynamicColorSeeds = ({
  Color? lightSeed,
  Color? darkSeed,
  Color accentColor,
});

extension DynamicColorSeedsExt on DynamicColorSeeds {
  Color seedOf(Brightness brightness) =>
      switch (brightness) {
        Brightness.light => lightSeed,
        Brightness.dark => darkSeed,
      } ??
      accentColor;
}

@Riverpod(keepAlive: true)
class DynamicColor extends _$DynamicColor {
  @override
  DynamicColorSeeds build() {
    return (
      lightSeed: null,
      darkSeed: null,
      accentColor: const Color(defaultPrimaryColor),
    );
  }

  void seed({Color? lightSeed, Color? darkSeed, required Color accentColor}) {
    state = (
      lightSeed: lightSeed,
      darkSeed: darkSeed,
      accentColor: accentColor,
    );
  }
}

@riverpod
ColorScheme genColorScheme(
  Ref ref,
  Brightness brightness, {
  Color? color,
  bool ignoreConfig = false,
  bool? pureBlack,
}) {
  final settings = ref.watch(
    themeSettingProvider.select(
      (state) => (
        primary: state.primaryColor,
        style: state.colorStyle,
        black: state.pureBlack,
      ),
    ),
  );
  final seed =
      color ??
      (ignoreConfig
          ? const Color(defaultPrimaryColor)
          : settings.primary == null
          ? ref.watch(dynamicColorProvider).seedOf(brightness)
          : Color(settings.primary!));
  return hotaruColorScheme(
    brightness,
    accent:
        seed.toARGB32() == defaultPrimaryColor &&
            settings.style == ColorStyle.vivid
        ? null
        : seed,
    style: settings.style,
    pureBlack: pureBlack ?? (!ignoreConfig && settings.black),
  );
}

typedef WindowBlurRequest = ({bool enabled, Brightness brightness, Color tint});

@riverpod
WindowBlurRequest windowBlurRequest(Ref ref) {
  final enabled = ref.watch(
    themeSettingProvider.select((state) => state.sidebarBlur),
  );
  final brightness = ref.watch(currentBrightnessProvider);
  final colorScheme = ref.watch(genColorSchemeProvider(brightness));
  return (
    enabled: enabled,
    brightness: brightness,
    tint: colorScheme.surfaceContainer,
  );
}

@riverpod
Brightness currentBrightness(Ref ref) {
  final themeMode = ref.watch(
    themeSettingProvider.select((state) => state.themeMode),
  );
  final systemBrightness = ref.watch(systemBrightnessProvider);
  return switch (themeMode) {
    ThemeMode.system => systemBrightness,
    ThemeMode.light => Brightness.light,
    ThemeMode.dark => Brightness.dark,
  };
}
