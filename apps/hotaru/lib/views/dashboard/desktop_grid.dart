import 'dart:math' as math;

import 'package:hotaru/common/common.dart';
import 'package:hotaru/enum/enum.dart';
import 'package:hotaru/models/models.dart';
import 'package:hotaru/providers/providers.dart';
import 'package:hotaru/ui/icons/icons.dart';
import 'package:hotaru/widgets/widgets.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'layout.dart';
import 'widget_registry.dart';

const _maxColumnWidth = DashboardSizing.maxColumn;
const _sidePadding = DashboardSizing.inset;

Map<DashboardWidget, DashboardTier> _tiersOf(List<DashboardWidget> order) => {
  for (final widget in order) widget: widget.tier,
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
  List<DashboardPlacement> placements,
  double scale,
) {
  final room = maxWidth - _sidePadding * 2 - gap * (columns - 1);
  final cell = math.min(room / columns, _maxColumnWidth * scale);
  final contentWidth = cell * columns + gap * (columns - 1);
  final inset = math.max(0.0, (maxWidth - _sidePadding * 2 - contentWidth) / 2);
  final totalHeight = placements.fold(
    0.0,
    (height, item) => math.max(height, item.bottom),
  );
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
    final widths = ref.watch(
      appSettingProvider.select((state) => state.dashboardWidgetSpans),
    );
    final placements = placeDashboardWidgets(
      order,
      _tiersOf(order),
      columns,
      widths: widths,
    );
    final duration = _motionOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final geometry = _geometry(
          constraints.maxWidth,
          columns,
          gap,
          placements,
          DashboardDensityScope.scaleOf(context),
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

class _DesktopDashboardEditorState extends ConsumerState<DesktopDashboardEditor>
    with SingleTickerProviderStateMixin {
  late List<DashboardWidget> _order;
  late Map<String, int> _widths;
  List<DashboardWidget>? _dropOrder;
  DashboardWidget? _dragging;
  final _gridKey = GlobalKey();
  final _viewportKey = GlobalKey();
  late final ScrollController _scroll;
  late final Ticker _edgeTicker = createTicker(_scrollAtEdge);
  Duration? _lastTick;
  double _edgeVelocity = 0;
  DragTargetDetails<DashboardWidget>? _lastDrag;
  _GridGeometry? _dragGeometry;

  void _stopEdgeScroll() {
    _edgeTicker.stop();
    _lastTick = null;
    _edgeVelocity = 0;
  }

  void _updateEdgeScroll(DragUpdateDetails details) {
    final box = _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (_dragging == null || box == null || !_scroll.hasClients) return;
    final pointer = box.globalToLocal(details.globalPosition);
    const edge = 48.0;
    final room = math.min(edge, box.size.height / 4);
    _edgeVelocity = pointer.dx < 0 || pointer.dx > box.size.width
        ? 0
        : pointer.dy < room
        ? -600 * ((room - pointer.dy) / room).clamp(0.0, 1.0)
        : pointer.dy > box.size.height - room
        ? 600 * ((pointer.dy - box.size.height + room) / room).clamp(0.0, 1.0)
        : 0;
    if (_edgeVelocity == 0) {
      _stopEdgeScroll();
    } else if (!_edgeTicker.isActive) {
      _lastTick = null;
      _edgeTicker.start();
    }
  }

  void _scrollAtEdge(Duration elapsed) {
    if (!mounted || _dragging == null || !_scroll.hasClients) {
      _stopEdgeScroll();
      return;
    }
    final seconds = _lastTick == null
        ? 1 / 60
        : ((elapsed - _lastTick!).inMicroseconds / 1000000).clamp(0.0, 0.05);
    _lastTick = elapsed;
    final position = _scroll.position;
    final next = (position.pixels + _edgeVelocity * seconds).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if ((next - position.pixels).abs() < 0.1) {
      _stopEdgeScroll();
      return;
    }
    _scroll.jumpTo(next);
    final details = _lastDrag;
    final geometry = _dragGeometry;
    if (details != null && geometry != null) {
      final order = _dropOrder ?? _order;
      _dragMoved(
        details,
        placeDashboardWidgets(
          order,
          _tiersOf(order),
          widget.columns,
          widths: _widths,
        ),
        geometry,
      );
    }
  }

  @override
  void dispose() {
    _stopEdgeScroll();
    _edgeTicker.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _scroll = sheetScrollController(context);
    final setting = ref.read(appSettingProvider);
    _widths = Map.of(setting.dashboardWidgetSpans);
    _order = [
      for (final item in setting.dashboardWidgets)
        if (item.platforms.contains(widget.platform)) item,
    ];
  }

  void _finishDrag({required bool accept}) {
    _stopEdgeScroll();
    _lastDrag = null;
    _dragGeometry = null;
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
            dashboardWidgetSpans: {
              ...state.dashboardWidgetSpans,
              for (final item in DashboardWidget.values)
                if (item.platforms.contains(widget.platform))
                  DashboardWidth.storageKey(item):
                      _widths[DashboardWidth.storageKey(item)] ??
                      item.tier.columns(4),
            },
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
    _stopEdgeScroll();
    setState(() {
      for (final item in DashboardWidget.values) {
        if (item.platforms.contains(widget.platform)) {
          _widths[DashboardWidth.storageKey(item)] = item.tier.columns(4);
        }
      }
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
    _lastDrag = details;
    _dragGeometry = geometry;
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
    if (target == null) return;
    final candidate = [..._order]..remove(dragged);
    final index = candidate.indexOf(target) + (after ? 1 : 0);
    candidate.insert(index, dragged);
    if (!listEquals(candidate, _dropOrder ?? _order)) {
      setState(() => _dropOrder = candidate);
    }
  }

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    final colorScheme = context.colorScheme;
    final placements = placeDashboardWidgets(
      _dropOrder ?? _order,
      _tiersOf(_dropOrder ?? _order),
      widget.columns,
      widths: _widths,
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
          placements,
          DashboardDensityScope.scaleOf(context),
        );
        return SingleChildScrollView(
          key: _viewportKey,
          controller: _scroll,
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
          Draggable<DashboardWidget>(
            data: item,
            feedback: Material(
              type: MaterialType.transparency,
              child: SizedBox(
                width: rect.width,
                height: rect.height,
                child: CustomPaint(
                  painter: _GhostPainter(
                    Offset.zero & rect.size,
                    colorScheme.primary,
                  ),
                ),
              ),
            ),
            childWhenDragging: Opacity(
              opacity: 0.25,
              child: cardContent(keyed: false),
            ),
            onDragStarted: () => setState(() {
              _dragging = item;
              _dropOrder = null;
            }),
            onDragUpdate: _updateEdgeScroll,
            onDragEnd: (_) => _finishDrag(accept: false),
            onDraggableCanceled: (_, _) => _finishDrag(accept: false),
            child: cardContent(keyed: true),
          ),
          PositionedDirectional(
            bottom: 4,
            start: 8,
            child: Material(
              color: colorScheme.surface,
              shape: AppShape.full,
              child: PopupMenuButton<DashboardWidth>(
                key: ValueKey('width-${item.name}'),
                tooltip: context.appLocalizations.dashboardCardWidth,
                onSelected: (width) => setState(() {
                  _widths[DashboardWidth.storageKey(item)] = width.span;
                }),
                itemBuilder: (context) => [
                  for (final width in DashboardWidth.values)
                    if (width.span >= item.tier.columns(4))
                      CheckedPopupMenuItem(
                        value: width,
                        checked:
                            DashboardWidth.of(item, item.tier, _widths) ==
                            width,
                        child: Text('${width.span}×'),
                      ),
                ],
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  child: Text(
                    '${DashboardWidth.of(item, item.tier, _widths).span}×',
                    style: AppTextStyle.caption1.of(context),
                  ),
                ),
              ),
            ),
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
