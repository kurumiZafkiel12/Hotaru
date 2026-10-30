import 'package:hotaru/common/common.dart';
import 'package:hotaru/enum/enum.dart';
import 'package:hotaru/common/country_names.dart';
import 'package:hotaru/ui/icons/icons.dart';
import 'package:hotaru/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';

class ThemeDashboardPreview extends StatelessWidget {
  const ThemeDashboardPreview({
    super.key,
    required this.colors,
    required this.navigation,
    this.selected = 0,
    this.tabAnimation = TabAnimation.fade,
  });

  final ColorScheme colors;
  final Widget navigation;
  final int selected;
  final TabAnimation tabAnimation;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720),
      child: Theme(
        data: Theme.of(context).withAppColorScheme(colors).withAppSurfaces,
        child: Builder(
          builder: (context) {
            final l10n = context.appLocalizations;
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              padding: const EdgeInsets.all(12),
              decoration: ShapeDecoration(
                color: colors.surface,
                shape: AppShape.xl,
              ),
              child: Column(
                spacing: 10,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          switch (selected) {
                            1 => l10n.proxies,
                            2 => l10n.profiles,
                            3 => l10n.tools,
                            _ => l10n.dashboard,
                          },
                          style: AppTextStyle.subheadline.of(
                            context,
                            emphasized: true,
                          ),
                        ),
                      ),
                      Text(
                        l10n.preview,
                        style: AppTextStyle.caption1
                            .of(context)
                            .copyWith(color: colors.onSurfaceVariant),
                      ),
                    ],
                  ),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final status = CommonCard(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          spacing: 10,
                          children: [
                            SizedBox(
                              width: 38,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    'JP'.countryFlagEmoji,
                                    style: AppTextStyle.title2
                                        .of(context)
                                        .copyWith(
                                          fontFamily: FontFamily.twEmoji.value,
                                        ),
                                  ),
                                  Text(
                                    'JP',
                                    style: AppTextStyle.caption2.of(context),
                                  ),
                                  Text(
                                    countryName(
                                          'JP',
                                          Localizations.localeOf(
                                            context,
                                          ).languageCode,
                                        ) ??
                                        'JP',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: AppTextStyle.caption2.of(context),
                                  ),
                                ],
                              ),
                            ),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                spacing: 6,
                                children: [
                                  Text(
                                    '192.0.2.10',
                                    style: AppTextStyle.headline
                                        .of(context)
                                        .toJetBrainsMono,
                                  ),
                                  Wrap(
                                    spacing: 10,
                                    runSpacing: 6,
                                    children: [
                                      for (final label in [
                                        l10n.statusIpOrigin,
                                        l10n.statusAccessType,
                                        l10n.statusNetworkQuality,
                                      ])
                                        Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              label,
                                              style: AppTextStyle.caption2
                                                  .of(context)
                                                  .copyWith(
                                                    color:
                                                        colors.onSurfaceVariant,
                                                  ),
                                            ),
                                            Text(
                                              l10n.unknown,
                                              style: AppTextStyle.caption2.of(
                                                context,
                                              ),
                                            ),
                                          ],
                                        ),
                                    ],
                                  ),
                                  Text(
                                    '—  ·  —',
                                    style: AppTextStyle.caption2.of(context),
                                  ),
                                ],
                              ),
                            ),
                            DecoratedBox(
                              decoration: ShapeDecoration(
                                color: colors.primary,
                                shape: AppShape.full,
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(10),
                                child: GlyphIcon(
                                  AppGlyphs.playPause(0),
                                  color: colors.onPrimary,
                                  size: 18,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                      final secondary = Column(
                        spacing: 8,
                        children: [
                          CommonCard(
                            padding: const EdgeInsets.all(10),
                            child: Row(
                              children: [
                                for (final label in [
                                  l10n.upload,
                                  l10n.download,
                                ])
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          label,
                                          style: AppTextStyle.caption2.of(
                                            context,
                                          ),
                                        ),
                                        Text(
                                          '— B/s',
                                          style: AppTextStyle.subheadline
                                              .of(context)
                                              .toJetBrainsMono
                                              .copyWith(color: colors.primary),
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          CommonCard(
                            padding: const EdgeInsets.all(8),
                            child: Row(
                              spacing: 4,
                              children: [
                                for (final (index, label) in [
                                  l10n.rule,
                                  l10n.global,
                                  l10n.direct,
                                ].indexed)
                                  Expanded(
                                    child: DecoratedBox(
                                      decoration: ShapeDecoration(
                                        color: index == 0
                                            ? colors.primary
                                            : colors.surfaceContainerHigh,
                                        shape: AppShape.md,
                                      ),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 6,
                                        ),
                                        child: Text(
                                          label,
                                          textAlign: TextAlign.center,
                                          style: AppTextStyle.caption2
                                              .of(context)
                                              .copyWith(
                                                color: index == 0
                                                    ? colors.onPrimary
                                                    : colors.onSurface,
                                              ),
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      );
                      if (selected != 0) {
                        final titles = switch (selected) {
                          1 => [l10n.proxies, l10n.delay, l10n.outboundMode],
                          2 => [l10n.profiles, l10n.rule, l10n.resources],
                          _ => [
                            l10n.speedTest,
                            l10n.dnsLeakTitle,
                            l10n.ipPortraitTitle,
                          ],
                        };
                        return AnimatedSwitcher(
                          duration: context.motionDuration(
                            const Duration(milliseconds: 250),
                          ),
                          transitionBuilder: (child, animation) =>
                              tabAnimation == TabAnimation.fade
                              ? FadeTransition(opacity: animation, child: child)
                              : SlideTransition(
                                  position: Tween(
                                    begin: const Offset(0.03, 0),
                                    end: Offset.zero,
                                  ).animate(animation),
                                  child: FadeTransition(
                                    opacity: animation,
                                    child: child,
                                  ),
                                ),
                          child: CommonCard(
                            key: ValueKey(selected),
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              spacing: 10,
                              children: [
                                for (final title in titles)
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          title,
                                          style: AppTextStyle.subheadline.of(
                                            context,
                                          ),
                                        ),
                                      ),
                                      const GlyphIcon(
                                        AppGlyphs.chevronForward,
                                        size: 16,
                                      ),
                                    ],
                                  ),
                              ],
                            ),
                          ),
                        );
                      }
                      return constraints.maxWidth >= 560
                          ? Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              spacing: 10,
                              children: [
                                Expanded(flex: 3, child: status),
                                Expanded(flex: 2, child: secondary),
                              ],
                            )
                          : Column(spacing: 8, children: [status, secondary]);
                    },
                  ),
                  navigation,
                ],
              ),
            );
          },
        ),
      ),
    ),
  );
}
