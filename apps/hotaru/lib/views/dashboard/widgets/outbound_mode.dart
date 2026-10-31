import 'package:hotaru/common/common.dart';
import 'package:hotaru/enum/enum.dart';
import 'package:hotaru/providers/providers.dart';
import 'package:hotaru/ui/icons/icons.dart';
import 'package:hotaru/ui/ui.dart';
import 'package:hotaru/views/dashboard/layout.dart';
import 'package:hotaru/views/dashboard/style.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'card.dart';
import '../../routing_configs.dart';

Glyph _glyphOf(Mode mode) => switch (mode) {
  Mode.rule => AppGlyphs.rules,
  Mode.global => AppGlyphs.proxies,
  Mode.direct => AppGlyphs.target,
};

void _changeMode(WidgetRef ref, Mode mode) {
  if (ref.read(patchClashConfigProvider).mode == mode) return;
  ref.read(setupActionProvider.notifier).changeMode(mode);
}

class OutboundModeCard extends ConsumerWidget {
  const OutboundModeCard({super.key});

  static const _outer = 26.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final desktop = DashboardDensityScope.of(context).isDesktop;
    final showTitle = !desktop || DashboardDensityScope.scaleOf(context) <= 1;
    final mode = ref.watch(
      patchClashConfigProvider.select((state) => state.mode),
    );
    final routingEnabled = ref.watch(
      appSettingProvider.select((state) => state.routingRulesEnabled),
    );
    final busy = ref.watch(routingConfigsActionProvider);
    final strings = context.appLocalizations;
    final options = [
      (Mode.rule, false, strings.routingSubscriptionMode, AppGlyphs.rules),
      (Mode.rule, true, strings.routingConfigMode, AppGlyphs.profiles),
      (Mode.global, false, strings.global, AppGlyphs.proxies),
      (Mode.direct, false, strings.direct, AppGlyphs.target),
    ];
    Future<void> choose(Mode next, bool configuration) async {
      if (busy) return;
      if (mode == next &&
          (next != Mode.rule || configuration == routingEnabled)) {
        return;
      }
      if (next != Mode.rule) {
        _changeMode(ref, next);
        return;
      }
      final settings = ref.read(appSettingProvider);
      if (configuration && settings.activeRoutingConfigId == null) {
        await BaseNavigator.push(context, const RoutingConfigsView());
        return;
      }
      try {
        await ref
            .read(routingConfigsActionProvider.notifier)
            .useSource(configuration);
      } catch (_) {
        if (context.mounted) {
          dialogs.showNotifier(
            strings.routingConfigFailed,
            level: MessageLevel.error,
          );
        }
      }
    }

    final tone = DashboardColors.of(context).tone;
    final style = AppTextStyle.footnote.of(context, emphasized: true);
    return DashboardCard(
      padding: DashboardDensityScope.of(context).isDesktop
          ? const EdgeInsets.all(10)
          : null,
      semanticLabel: context.appLocalizations.outboundMode,
      child: Column(
        children: [
          if (showTitle) ...[
            DashboardCardHeader(
              glyph: AppGlyphs.split,
              title: context.appLocalizations.outboundMode,
              trailing: [if (busy) const CommonCircleLoading(size: 14)],
            ),
            SizedBox(height: desktop ? 2 : 6),
          ],
          DashboardConnectedGroup(
            children: [
              for (final (index, (item, configuration, label, glyph))
                  in options.indexed)
                Expanded(
                  child: DashboardConnectedButton(
                    selected:
                        item == mode &&
                        (item != Mode.rule || configuration == routingEnabled),
                    first: index == 0,
                    last: index == options.length - 1,
                    outer: _outer,
                    inner: 12,
                    background: tone,
                    semanticLabel: label,
                    onTap: () => choose(item, configuration),
                    builder: (foreground) => SizedBox(
                      height: desktop
                          ? showTitle
                                ? DashboardSizing.desktopControlHeight
                                : 48
                          : 40,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        spacing: 6,
                        children: [
                          GlyphIcon(glyph, size: 16, color: foreground),
                          Flexible(
                            child: Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: style.copyWith(color: foreground),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The desktop control row's mode switch; its buttons sit as far in from the
/// card's ends as from its edges so their corners stay concentric.
class OutboundModeBar extends ConsumerWidget {
  const OutboundModeBar({super.key});

  static const _inset = 8.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final density = DashboardDensityScope.of(context);
    final mode = ref.watch(
      patchClashConfigProvider.select((state) => state.mode),
    );
    final appLocalizations = context.appLocalizations;
    final outer = dashboardCardRadius(density) - _inset;
    final style = AppTextStyle.subheadline.of(context, emphasized: true);
    return DashboardCard(
      semanticLabel: appLocalizations.outboundMode,
      padding: EdgeInsetsDirectional.fromSTEB(
        dashboardCardPadding(density).left,
        _inset,
        _inset,
        _inset,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) => Row(
          spacing: 16,
          children: [
            GlyphIcon(
              AppGlyphs.split,
              size: 18,
              color: context.colorScheme.onSurfaceVariant,
            ),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: constraints.maxWidth / 4),
              child: Text(
                appLocalizations.outboundMode,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: DashboardText.cardTitle(context),
              ),
            ),
            Expanded(
              child: DashboardConnectedGroup(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (index, item) in Mode.values.indexed)
                    Expanded(
                      child: DashboardConnectedButton(
                        selected: item == mode,
                        first: index == 0,
                        last: index == Mode.values.length - 1,
                        outer: outer,
                        inner: 10,
                        background: DashboardColors.of(context).tone,
                        semanticLabel: item.label,
                        onTap: () => _changeMode(ref, item),
                        builder: (foreground) => Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          spacing: 6,
                          children: [
                            GlyphIcon(
                              _glyphOf(item),
                              size: 18,
                              color: foreground,
                            ),
                            Flexible(
                              child: Text(
                                item.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: style.copyWith(color: foreground),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
