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

Map<DashboardWidget, DashboardBand> _bandsOf(List<DashboardWidget> order) => {
  for (final widget in order) widget: widget.band,
};

Map<DashboardWidget, int> _widthsOf(List<DashboardWidget> order) => {
  for (final widget in order) widget: widget.span,
};

class _GridGeometry {
  const _GridGeometry({
    required this.cellWidth,
    required this.inset,
    required this.contentWidth,
    required this.totalHeight,
  });

  final double cellWidth;
  final double inset;
  final double contentWidth;
  final double totalHeight;

  Rect rectOf(DashboardPlacement placement, double gap) => Rect.fromLTWH(
    placement.column * (cellWidth + gap),
    placement.top,
    placement.columns * cellWidth + (placement.columns - 1) * gap,
    placement.height,
  );
}

_GridGeometry _geometry(
  double maxWidth,
  int columns,
  double gap,
  double scale,
  List<DashboardPlacement> placements,
) {
  final room = maxWidth - _sidePadding * 2 - gap * (columns - 1);
  final cell = math.min(room / columns, _maxColumnWidth * scale);
  final contentWidth = cell * columns + gap * (columns - 1);
  final inset = math.max(0.0, (maxWidth - _sidePadding * 2 - contentWidth) / 2);
  var totalHeight = 0.0;
  for (final placement in placements) {
    totalHeight = math.max(totalHeight, placement.bottom);
  }
  return _GridGeometry(
    cellWidth: cell,
    inset: inset,
    contentWidth: contentWidth,
    totalHeight: totalHeight,
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
    final order = [
      for (final widget in saved)
        if (widget.platforms.contains(platform)) widget,
    ];
    final placements = placeDashboardWidgets(
      order,
      _bandsOf(order),
      _widthsOf(order),
      columns,
      scale: DashboardDensityScope.scaleOf(context),
    );
    final duration = _motionOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final geometry = _geometry(
          constraints.maxWidth,
          columns,
          gap,
          DashboardDensityScope.scaleOf(context),
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
  List<DashboardWidget>? _dropOrder;
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

  void _finishDrag({required bool accept}) {
    if (_dragging == null && _dropOrder == null) {
      return;
    }
    setState(() {
      if (accept && _dropOrder != null) {
        _order = _dropOrder!;
      }
      _dropOrder = null;
      _dragging = null;
    });
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
            // Card sizes are fixed by band; spans saved by 0.0.4's resizable
            // editor no longer apply and are cleared on the next save.
            dashboardWidgetSpans: const {},
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
      _dropOrder = null;
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
    if (target == null) {
      // The probe is over a gap or the dragged card's own slot: the live
      // order already shows where the drop lands, so leave it as it is
      // instead of snapping the card to an end.
      return;
    }
    final candidate = [..._order]..remove(dragged);
    var index = candidate.indexOf(target);
    if (after) {
      index++;
    }
    candidate.insert(index, dragged);
    if (!_sameOrder(_dropOrder, candidate)) {
      // The other cards reflow to the drop order live, so the grid the
      // user sees while dragging is the grid they get on release.
      setState(() => _dropOrder = candidate);
    }
  }

  bool _sameOrder(List<DashboardWidget>? a, List<DashboardWidget> b) {
    if (a == null || a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final scale = DashboardDensityScope.scaleOf(context);
    final appLocalizations = context.appLocalizations;
    final colorScheme = context.colorScheme;
    final effectiveOrder = _dropOrder ?? _order;
    final placements = placeDashboardWidgets(
      effectiveOrder,
      _bandsOf(effectiveOrder),
      _widthsOf(effectiveOrder),
      widget.columns,
      scale: scale,
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
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.end,
                children: [
                  TonalButton(
                    glyph: AppGlyphs.add,
                    label: appLocalizations.dashboardAddableSection,
                    onPressed: addable.isEmpty
                        ? null
                        : () async {
                            final added = await showExtend<DashboardWidget>(
                              context,
                              builder: (_) =>
                                  _AddDashboardWidget(items: addable),
                            );
                            if (added != null &&
                                mounted &&
                                !_order.contains(added)) {
                              setState(() => _order = [..._order, added]);
                            }
                          },
                  ),
                  TonalButton(
                    glyph: AppGlyphs.reset,
                    label: appLocalizations.dashboardRestoreDefaults,
                    onPressed: _resetDefaults,
                  ),
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
                onWillAcceptWithDetails: (details) =>
                    _order.contains(details.data),
                onMove: (details) => _dragMoved(details, placements, geometry),
                onAcceptWithDetails: (details) {
                  _dragMoved(details, placements, geometry);
                  _finishDrag(accept: true);
                },
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
            delay: widget.platform == SupportPlatform.Android
                ? const Duration(milliseconds: 350)
                : Duration.zero,
            data: item,
            feedback: Material(
              type: MaterialType.transparency,
              child: Transform.scale(
                scale: 1.02,
                child: SizedBox(
                  width: rect.width,
                  height: rect.height,
                  child: AbsorbPointer(
                    child: RepaintBoundary(child: item.card),
                  ),
                ),
              ),
            ),
            childWhenDragging: CustomPaint(
              painter: _GhostPainter(
                Offset.zero & rect.size,
                colorScheme.primary,
              ),
            ),
            onDragStarted: () => setState(() {
              _dragging = item;
              _dropOrder = null;
            }),
            onDragEnd: (_) => _finishDrag(accept: false),
            onDraggableCanceled: (_, _) => _finishDrag(accept: false),
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

class _AddDashboardWidget extends StatelessWidget {
  const _AddDashboardWidget({required this.items});

  final List<DashboardWidget> items;

  @override
  Widget build(BuildContext context) => BaseScaffold(
    title: context.appLocalizations.dashboardAddableSection,
    body: ListView(
      padding: EdgeInsets.fromLTRB(
        16,
        context.appBarInset,
        16,
        context.bottomInset + 16,
      ),
      children: [
        for (final item in items)
          ListItem(
            leading: GlyphIcon(item.glyph),
            title: Text(item.label(context)),
            trailing: IconButton(
              tooltip: '${context.appLocalizations.add} ${item.label(context)}',
              onPressed: () => Navigator.of(context).pop(item),
              icon: const GlyphIcon(AppGlyphs.add),
            ),
          ),
      ],
    ),
  );
}

class _GhostPainter extends CustomPainter {
  const _GhostPainter(this.rect, this.color);

  final Rect? rect;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = this.rect;
    if (rect == null) return;
    final path = AppShape.lg.getOuterPath(rect);
    canvas.drawPath(path, Paint()..color = color.withValues(alpha: 0.10));
    final stroke = Paint()
      ..color = color.withValues(alpha: 0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final metric in path.computeMetrics()) {
      for (var at = 0.0; at < metric.length; at += 12) {
        canvas.drawPath(
          metric.extractPath(at, math.min(at + 6, metric.length)),
          stroke,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_GhostPainter oldDelegate) =>
      rect != oldDelegate.rect || color != oldDelegate.color;
}
