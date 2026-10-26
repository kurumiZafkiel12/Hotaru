import 'dart:math' as math;

import 'package:hotaru/common/common.dart';
import 'package:hotaru/enum/enum.dart';
import 'package:hotaru/models/models.dart';
import 'package:hotaru/providers/providers.dart';
import 'package:hotaru/ui/icons/icons.dart';
import 'package:hotaru/widgets/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'layout.dart';
import 'widget_registry.dart';

const _maxColumnWidth = 400.0;
const _sidePadding = 16.0;

Map<DashboardWidget, DashboardTier> _tiersOf(List<DashboardWidget> order) => {
  for (final widget in order) widget: widget.tier,
};

class _GridGeometry {
  const _GridGeometry({
    required this.cellWidth,
    required this.unit,
    required this.inset,
    required this.contentWidth,
    required this.totalHeight,
  });

  final double cellWidth;
  final double unit;
  final double inset;
  final double contentWidth;
  final double totalHeight;

  Rect rectOf(DashboardPlacement placement, double gap) => Rect.fromLTWH(
    placement.column * (cellWidth + gap),
    placement.row * (unit + gap),
    placement.columns * cellWidth + (placement.columns - 1) * gap,
    placement.rows * unit + (placement.rows - 1) * gap,
  );
}

_GridGeometry _geometry(
  double maxWidth,
  int columns,
  double gap,
  double scale,
  bool compact,
  List<DashboardPlacement> placements,
) {
  final room = maxWidth - _sidePadding * 2 - gap * (columns - 1);
  final cell = math.min(room / columns, _maxColumnWidth * scale);
  final contentWidth = cell * columns + gap * (columns - 1);
  final inset = math.max(0.0, (maxWidth - _sidePadding * 2 - contentWidth) / 2);
  final unit = dashboardUnitHeight(compact: compact) * scale;
  var rows = 0;
  for (final placement in placements) {
    rows = math.max(rows, placement.row + placement.rows);
  }
  return _GridGeometry(
    cellWidth: cell,
    unit: unit,
    inset: inset,
    contentWidth: contentWidth,
    totalHeight: rows == 0 ? 0 : rows * unit + (rows - 1) * gap,
  );
}

Duration _motionOf(BuildContext context) =>
    context.motionDuration(const Duration(milliseconds: 280));

class DesktopDashboardGrid extends ConsumerWidget {
  const DesktopDashboardGrid({
    super.key,
    required this.platform,
    required this.columns,
    required this.gap,
    required this.topPadding,
    required this.cardKeyOf,
  });

  final SupportPlatform platform;
  final int columns;
  final double gap;
  final double topPadding;
  final GlobalKey Function(DashboardWidget widget) cardKeyOf;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final saved = ref.watch(
      dashboardStateProvider.select((state) => state.dashboardWidgets),
    );
    final compact = DashboardDensityScope.of(context).isCompact;
    final order = [
      for (final widget in saved)
        if (widget.platforms.contains(platform)) widget,
    ];
    final placements = placeDashboardWidgets(order, _tiersOf(order), columns);
    final duration = _motionOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final geometry = _geometry(
          constraints.maxWidth,
          columns,
          gap,
          DashboardDensityScope.scaleOf(context),
          compact,
          placements,
        );
        return SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(
            _sidePadding + geometry.inset,
            topPadding,
            _sidePadding + geometry.inset,
            _sidePadding + MediaQuery.paddingOf(context).bottom,
          ),
          child: SizedBox(
            width: geometry.contentWidth,
            height: geometry.totalHeight,
            child: Stack(
              children: [
                for (final placement in placements)
                  AnimatedPositioned(
                    key: ValueKey(placement.widget),
                    duration: duration,
                    curve: Curves.easeOutCubic,
                    left: geometry.rectOf(placement, gap).left,
                    top: geometry.rectOf(placement, gap).top,
                    width: geometry.rectOf(placement, gap).width,
                    height: geometry.rectOf(placement, gap).height,
                    child: RepaintBoundary(
                      key: cardKeyOf(placement.widget),
                      child: placement.widget.card,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class DesktopDashboardEditor extends ConsumerStatefulWidget {
  const DesktopDashboardEditor({
    super.key,
    required this.platform,
    required this.columns,
    required this.gap,
    required this.topPadding,
    required this.cardKeyOf,
    required this.onDone,
    required this.onCancel,
  });

  final SupportPlatform platform;
  final int columns;
  final double gap;
  final double topPadding;
  final GlobalKey Function(DashboardWidget widget) cardKeyOf;
  final VoidCallback onDone;
  final VoidCallback onCancel;

  @override
  ConsumerState<DesktopDashboardEditor> createState() =>
      _DesktopDashboardEditorState();
}

class _DesktopDashboardEditorState
    extends ConsumerState<DesktopDashboardEditor> {
  late List<DashboardWidget> _order;
  DashboardWidget? _dragging;
  final _gridKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    final setting = ref.read(appSettingProvider);
    _order = [
      for (final item in setting.dashboardWidgets)
        if (item.platforms.contains(widget.platform)) item,
    ];
  }

  void _save() {
    ref
        .read(appSettingProvider.notifier)
        .update(
          (state) => state.copyWith(
            dashboardWidgets: _keepingOtherPlatforms(
              state.dashboardWidgets,
              _order,
            ),
          ),
        );
    widget.onDone();
  }

  List<DashboardWidget> _keepingOtherPlatforms(
    List<DashboardWidget> saved,
    List<DashboardWidget> shown,
  ) {
    final result = [...shown];
    var at = 0;
    for (final card in saved) {
      if (card.platforms.contains(widget.platform)) {
        final index = result.indexOf(card);
        if (index != -1) at = index + 1;
      } else {
        result.insert(at++, card);
      }
    }
    return result;
  }

  void _resetDefaults() {
    setState(() {
      _order = [
        for (final item in platformDefaultDashboardWidgets)
          if (item.platforms.contains(widget.platform)) item,
      ];
      _dragging = null;
    });
  }

  void _dragMoved(
    DragTargetDetails<DashboardWidget> details,
    List<DashboardPlacement> placements,
    _GridGeometry geometry,
  ) {
    final dragged = _dragging;
    if (dragged == null) {
      return;
    }
    final box = _gridKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) {
      return;
    }
    final size = geometry.rectOf(
      placements.firstWhere((item) => item.widget == dragged),
      widget.gap,
    );
    final probe =
        box.globalToLocal(details.offset) +
        Offset(size.width / 2, size.height / 2);
    DashboardWidget? target;
    var after = false;
    for (final placement in placements) {
      if (placement.widget == dragged) {
        continue;
      }
      final rect = geometry.rectOf(placement, widget.gap);
      if (rect.contains(probe)) {
        target = placement.widget;
        after = probe.dx > rect.center.dx;
        break;
      }
    }
    final candidate = [..._order]..remove(dragged);
    if (target == null) {
      if (probe.dy <= 0) {
        candidate.insert(0, dragged);
      } else {
        candidate.add(dragged);
      }
    } else {
      var index = candidate.indexOf(target);
      if (after) {
        index++;
      }
      candidate.insert(index, dragged);
    }
    var changed = candidate.length != _order.length;
    for (var i = 0; !changed && i < candidate.length; i++) {
      changed = candidate[i] != _order[i];
    }
    if (changed) {
      setState(() => _order = candidate);
    }
  }

  @override
  Widget build(BuildContext context) {
    final compact = DashboardDensityScope.of(context).isCompact;
    final scale = DashboardDensityScope.scaleOf(context);
    final appLocalizations = context.appLocalizations;
    final colorScheme = context.colorScheme;
    final placements = placeDashboardWidgets(
      _order,
      _tiersOf(_order),
      widget.columns,
    );
    final addable = [
      for (final item in DashboardWidget.values)
        if (item.platforms.contains(widget.platform) && !_order.contains(item))
          item,
    ];
    final duration = _motionOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final geometry = _geometry(
          constraints.maxWidth,
          widget.columns,
          widget.gap,
          scale,
          compact,
          placements,
        );
        return SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(
            _sidePadding + geometry.inset,
            widget.topPadding,
            _sidePadding + geometry.inset,
            _sidePadding + MediaQuery.paddingOf(context).bottom,
          ),
          child: Column(
            spacing: widget.gap,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                spacing: 8,
                children: [
                  TonalButton(
                    glyph: AppGlyphs.reset,
                    label: appLocalizations.dashboardRestoreDefaults,
                    onPressed: _resetDefaults,
                  ),
                  const Spacer(),
                  TonalButton(
                    label: appLocalizations.cancel,
                    onPressed: widget.onCancel,
                  ),
                  FilledButton(
                    onPressed: _save,
                    child: Text(appLocalizations.done),
                  ),
                ],
              ),
              DragTarget<DashboardWidget>(
                onWillAcceptWithDetails: (_) => _dragging != null,
                onMove: (details) => _dragMoved(details, placements, geometry),
                onAcceptWithDetails: (_) => setState(() => _dragging = null),
                builder: (context, _, _) => SizedBox(
                  key: _gridKey,
                  width: geometry.contentWidth,
                  height: geometry.totalHeight,
                  child: Stack(
                    children: [
                      for (final placement in placements)
                        _animatedCell(
                          context,
                          placement,
                          geometry,
                          duration,
                          colorScheme,
                        ),
                    ],
                  ),
                ),
              ),
              if (addable.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  appLocalizations.dashboardAddableSection,
                  style: AppTextStyle.footnote.of(context, emphasized: true),
                ),
                for (final item in addable)
                  ListItem(
                    leading: GlyphIcon(item.glyph),
                    title: Text(item.label(context)),
                    trailing: IconButton(
                      tooltip: '${appLocalizations.add} ${item.label(context)}',
                      onPressed: () =>
                          setState(() => _order = [..._order, item]),
                      icon: const GlyphIcon(AppGlyphs.add),
                    ),
                  ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _animatedCell(
    BuildContext context,
    DashboardPlacement placement,
    _GridGeometry geometry,
    Duration duration,
    ColorScheme colorScheme,
  ) {
    final item = placement.widget;
    final rect = geometry.rectOf(placement, widget.gap);
    Widget cardContent({required bool keyed}) {
      return SizedBox(
        width: rect.width,
        height: rect.height,
        child: AbsorbPointer(
          child: keyed
              ? RepaintBoundary(key: widget.cardKeyOf(item), child: item.card)
              : RepaintBoundary(child: item.card),
        ),
      );
    }

    return AnimatedPositioned(
      key: ValueKey(item),
      duration: duration,
      curve: Curves.easeOutCubic,
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
      child: Stack(
        children: [
          LongPressDraggable<DashboardWidget>(
            data: item,
            feedback: Material(
              type: MaterialType.transparency,
              child: Opacity(opacity: 0.9, child: cardContent(keyed: false)),
            ),
            childWhenDragging: Opacity(
              opacity: 0.25,
              child: cardContent(keyed: false),
            ),
            onDragStarted: () => setState(() => _dragging = item),
            onDragEnd: (_) => setState(() => _dragging = null),
            onDraggableCanceled: (_, _) => setState(() => _dragging = null),
            child: cardContent(keyed: true),
          ),
          if (item.removable)
            PositionedDirectional(
              top: 0,
              end: 0,
              child: SizedBox.square(
                dimension: 28,
                child: IconButton(
                  tooltip:
                      '${context.appLocalizations.remove} ${item.label(context)}',
                  padding: EdgeInsets.zero,
                  style: IconButton.styleFrom(
                    backgroundColor: colorScheme.errorContainer,
                    foregroundColor: colorScheme.onErrorContainer,
                    minimumSize: const Size.square(28),
                    fixedSize: const Size.square(28),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () =>
                      setState(() => _order = [..._order]..remove(item)),
                  icon: GlyphIcon(
                    AppGlyphs.remove,
                    size: 16,
                    color: colorScheme.onErrorContainer,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
