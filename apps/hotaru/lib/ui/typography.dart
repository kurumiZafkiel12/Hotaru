import 'package:hotaru/ui/metrics.dart';
import 'package:material_ui/material_ui.dart';

enum AppTextStyle {
  display(
    40,
    44,
    desktopSize: 32,
    desktopLeading: 38,
    emphasizedWeight: FontWeight.w700,
  ),
  largeTitle(
    34,
    41,
    desktopSize: 28,
    desktopLeading: 34,
    emphasizedWeight: FontWeight.w700,
  ),
  title1(
    28,
    34,
    desktopSize: 24,
    desktopLeading: 30,
    emphasizedWeight: FontWeight.w700,
  ),
  pageTitle(
    24,
    30,
    desktopSize: 20,
    desktopLeading: 26,
    weight: FontWeight.w600,
    emphasizedWeight: FontWeight.w700,
  ),
  title2(
    22,
    28,
    desktopSize: 20,
    desktopLeading: 26,
    emphasizedWeight: FontWeight.w700,
  ),
  title3(20, 25, desktopSize: 17, desktopLeading: 22),
  headline(
    17,
    22,
    desktopSize: 15,
    desktopLeading: 20,
    weight: FontWeight.w600,
  ),
  body(17, 22, desktopSize: 15, desktopLeading: 20),
  callout(16, 21, desktopSize: 14, desktopLeading: 19),
  subheadline(15, 20, desktopSize: 13, desktopLeading: 18),
  footnote(13, 18, desktopSize: 12, desktopLeading: 16),
  caption1(12, 16),
  caption2(11, 13);

  const AppTextStyle(
    this.size,
    this.leading, {
    this.weight = FontWeight.w400,
    this.emphasizedWeight = FontWeight.w600,
    this.desktopSize,
    this.desktopLeading,
  });

  final double size;
  final double leading;
  final FontWeight weight;
  final FontWeight emphasizedWeight;
  final double? desktopSize;
  final double? desktopLeading;

  TextStyle of(BuildContext context, {bool emphasized = false}) => _apply(
    _slotOf(Theme.of(context).textTheme)!,
    emphasized: emphasized,
    desktop: usesDesktopMetrics(Theme.of(context).platform),
  );

  /// For text sized to the shape it marks, such as a letter in an icon.
  static TextStyle custom(
    BuildContext context, {
    required double size,
    required double leading,
    FontWeight weight = FontWeight.w400,
  }) {
    final textTheme = Theme.of(context).textTheme;
    final base = size < title3.size
        ? textTheme.bodyLarge
        : textTheme.titleLarge;
    return base!.copyWith(
      fontSize: size,
      height: leading / size,
      fontWeight: weight,
      letterSpacing: 0,
    );
  }

  // Typography.blackCupertino draws these slots with SF Pro Display and the
  // rest with SF Pro Text, which Apple switches between at 20 pt.
  TextStyle? _slotOf(TextTheme theme) => switch (this) {
    display || largeTitle => theme.headlineLarge,
    title1 => theme.headlineMedium,
    pageTitle || title2 => theme.headlineSmall,
    title3 => theme.titleLarge,
    headline => theme.titleMedium,
    body || callout => theme.bodyLarge,
    subheadline => theme.bodyMedium,
    footnote => theme.bodySmall,
    caption1 => theme.labelMedium,
    caption2 => theme.labelSmall,
  };

  TextStyle _apply(
    TextStyle base, {
    required bool emphasized,
    bool desktop = false,
  }) {
    final fontSize = desktop ? desktopSize ?? size : size;
    final lineHeight = desktop ? desktopLeading ?? leading : leading;
    return base.copyWith(
      fontSize: fontSize,
      height: lineHeight / fontSize,
      fontWeight: emphasized ? emphasizedWeight : weight,
      letterSpacing: 0,
    );
  }

  TextStyle? _on(
    TextStyle? base, {
    bool emphasized = false,
    bool desktop = false,
  }) => base == null
      ? null
      : _apply(base, emphasized: emphasized, desktop: desktop);
}

extension AppTypographyThemeExt on ThemeData {
  ThemeData get withAppTypography => copyWith(
    textTheme: _onAppScale(textTheme, desktop: usesDesktopMetrics(platform)),
    primaryTextTheme: _onAppScale(
      primaryTextTheme,
      desktop: usesDesktopMetrics(platform),
    ),
  );
}

TextTheme _onAppScale(
  TextTheme theme, {
  bool desktop = false,
}) => theme.copyWith(
  displayLarge: AppTextStyle.largeTitle._on(
    theme.displayLarge,
    desktop: desktop,
  ),
  displayMedium: AppTextStyle.largeTitle._on(
    theme.displayMedium,
    desktop: desktop,
  ),
  displaySmall: AppTextStyle.largeTitle._on(
    theme.displaySmall,
    desktop: desktop,
  ),
  headlineLarge: AppTextStyle.largeTitle._on(
    theme.headlineLarge,
    desktop: desktop,
  ),
  headlineMedium: AppTextStyle.title1._on(
    theme.headlineMedium,
    desktop: desktop,
  ),
  headlineSmall: AppTextStyle.title2._on(theme.headlineSmall, desktop: desktop),
  titleLarge: AppTextStyle.title3._on(theme.titleLarge, desktop: desktop),
  titleMedium: AppTextStyle.headline._on(theme.titleMedium, desktop: desktop),
  titleSmall: AppTextStyle.subheadline._on(
    theme.titleSmall,
    emphasized: true,
    desktop: desktop,
  ),
  bodyLarge: AppTextStyle.body._on(theme.bodyLarge, desktop: desktop),
  bodyMedium: AppTextStyle.subheadline._on(theme.bodyMedium, desktop: desktop),
  bodySmall: AppTextStyle.footnote._on(theme.bodySmall, desktop: desktop),
  labelLarge: AppTextStyle.subheadline._on(
    theme.labelLarge,
    emphasized: true,
    desktop: desktop,
  ),
  labelMedium: AppTextStyle.caption1._on(
    theme.labelMedium,
    emphasized: true,
    desktop: desktop,
  ),
  labelSmall: AppTextStyle.caption2._on(
    theme.labelSmall,
    emphasized: true,
    desktop: desktop,
  ),
);
