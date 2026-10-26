import 'dart:math' as math;

import 'package:hotaru/common/common.dart';
import 'package:hotaru/core/core.dart';
import 'package:hotaru/enum/enum.dart';
import 'package:hotaru/providers/providers.dart';
import 'package:hotaru/ui/icons/icons.dart';
import 'package:hotaru/widgets/widgets.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'desktop_grid.dart';
import 'edit.dart';
import 'layout.dart';
import 'style.dart';
import 'widget_registry.dart';
import 'widgets/core_status_button.dart';

class DashboardView extends ConsumerStatefulWidget {
  const DashboardView({super.key, this.platform});

  /// The host's platform when null.
  final SupportPlatform? platform;

  @override
  ConsumerState<DashboardView> createState() => _DashboardViewState();
}

class _DashboardViewState extends ConsumerState<DashboardView> {
  var _editing = false;
  final _cardKeys = <DashboardWidget, GlobalKey>{};
  (List<DashboardWidget>, Map<String, int>)? _editSnapshot;

  void _setEditing(bool editing) {
    setState(() => _editing = editing);
  }

  void _startEditing() {
    final setting = ref.read(appSettingProvider);
    _editSnapshot = (
      [...setting.dashboardWidgets],
      {...setting.dashboardWidgetSpans},
    );
    _setEditing(true);
  }

  void _cancelEditing() {
    final snapshot = _editSnapshot;
    if (snapshot != null) {
      ref
          .read(appSettingProvider.notifier)
          .update(
            (state) => state.copyWith(
              dashboardWidgets: snapshot.$1,
              dashboardWidgetSpans: snapshot.$2,
            ),
          );
    }
    _setEditing(false);
  }

  GlobalKey _cardKeyOf(DashboardWidget widget) =>
      _cardKeys.putIfAbsent(widget, GlobalKey.new);

  @override
  Widget build(BuildContext context) {
    final platform = widget.platform ?? SupportPlatform.currentPlatform;
    final viewSize = ref.watch(viewSizeProvider);
    final sideWidth = ref.watch(sideWidthProvider);
    final scale = math.max(1.0, MediaQuery.textScalerOf(context).scale(1));
    final size = Size(viewSize.width - sideWidth, viewSize.height) / scale;
    final isDesktop = DashboardDensity.of(size).isDesktop;
    final editing = _editing;
    final gap = cardSpacingOf(context, ref.watch(viewModeProvider));
    final appLocalizations = context.appLocalizations;
    return CommonScaffold(
      backgroundColor: DashboardColors.of(context).page,
      title: editing
          ? appLocalizations.editDashboard
          : appLocalizations.dashboard,
      actions: [if (!editing && coreLib == null) const CoreStatusButton()],
      confirmationAction: editing && !isDesktop
          ? IconButtonData(
              glyph: AppGlyphs.check,
              tooltip: appLocalizations.done,
              onPressed: () => _setEditing(false),
            )
          : null,
      iconActions: [
        if (!editing)
          IconButtonData(
            glyph: AppGlyphs.edit,
            tooltip: appLocalizations.editDashboard,
            onPressed: _startEditing,
          ),
      ],
      // The providers learn a resize a frame late, too late for the cards.
      body: DecoratedBox(
        decoration: const BoxDecoration(),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final room = constraints.biggest / scale;
            final layout = DashboardDensity.of(room);
            // The bar floats over the body; the dashboard scrolls below it
            // instead of sliding under the title.
            final band = context.appBarInset;
            final topGap = math.max(0.0, context.contentTopPadding - band);
            return Padding(
              padding: EdgeInsets.only(top: band),
              child: DashboardDensityScope(
                density: layout,
                scale: scale,
                child: layout.isDesktop
                    ? editing
                          ? DesktopDashboardEditor(
                              platform: platform,
                              columns: dashboardColumnsOf(room.width),
                              gap: 12,
                              topPadding: topGap,
                              cardKeyOf: _cardKeyOf,
                              onDone: () => _setEditing(false),
                              onCancel: _cancelEditing,
                            )
                          : DesktopDashboardGrid(
                              platform: platform,
                              columns: dashboardColumnsOf(room.width),
                              gap: 12,
                              topPadding: topGap,
                              cardKeyOf: _cardKeyOf,
                            )
                    : _MobileDashboard(
                        platform: platform,
                        gap: gap,
                        topPadding: topGap,
                        editing: editing,
                        cardKeyOf: _cardKeyOf,
                        onDone: () => _setEditing(false),
                      ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _MobileDashboard extends ConsumerWidget {
  const _MobileDashboard({
    required this.platform,
    required this.gap,
    required this.topPadding,
    required this.editing,
    required this.cardKeyOf,
    required this.onDone,
  });

  final SupportPlatform platform;
  final double gap;
  final double topPadding;
  final bool editing;
  final GlobalKey Function(DashboardWidget widget) cardKeyOf;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final saved = ref.watch(
      dashboardStateProvider.select((state) => state.dashboardWidgets),
    );
    final top = topPadding;
    final bottom = 16 + context.bottomInset;
    return CustomScrollView(
      // A viewport per card lays them all out and holds the scroll end still.
      scrollCacheExtent: editing
          ? ScrollCacheExtent.viewport(DashboardWidget.values.length.toDouble())
          : null,
      slivers: [
        SliverLayoutBuilder(
          builder: (context, constraints) {
            final side = dashboardMobileSideOf(constraints.crossAxisExtent);
            final widgets = [
              for (final widget in saved)
                if (widget.platforms.contains(platform)) widget,
            ];
            if (editing) {
              return DashboardEditor(
                platform: platform,
                widgets: widgets,
                cardKeyOf: cardKeyOf,
                padding: EdgeInsets.fromLTRB(side, top, side, bottom),
                gap: gap,
                onDone: onDone,
              );
            }
            return SliverPadding(
              padding: EdgeInsets.fromLTRB(side, top, side, bottom),
              // A lazy list estimates the cards it has not laid out from the
              // ones it has; cards this uneven move the scroll end as it goes.
              sliver: SliverToBoxAdapter(
                child: Column(
                  spacing: gap,
                  children: [
                    for (final widget in widgets)
                      RepaintBoundary(
                        key: cardKeyOf(widget),
                        child: widget.card,
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}
