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

const _maxColumnWidth = 360.0;
const _resizeStep = 44.0;

Map<DashboardWidget, DashboardSpan> _decodeSpans(Map<String, int> saved) => {
  for (final widget in DashboardWidget.values) widget: widget.spanFrom(saved),
};

class _GridGeometry {
  const _GridGeometry({required this.column, required this.inset});

  final double column;
  final double inset;

  double spanWidth(int columns, double gap) =>
      column * columns + gap * (columns - 1);
}

_GridGeometry _geometry(
  double maxWidth,
  int columns,
  double gap,
  double scale,
) {
  final room = maxWidth - 48 - gap * (columns - 1);
  final column = math.min(room / columns, _maxColumnWidth * scale);
  final inset = (room - column * columns) / 2;
  return _GridGeometry(column: column, inset: inset);
}

class DesktopDashboardGrid extends ConsumerWidget {
  const DesktopDashboardGrid({
    super.key,
    required this.platform,
    required this.columns,
    required this.gap,
    required this.cardKeyOf,
  });

  final SupportPlatform platform;
  final int columns;
  final double gap;
  final GlobalKey Function(DashboardWidget widget) cardKeyOf;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final setting = ref.watch(
      appSettingProvider.select(
        (state) => (
          widgets: state.dashboardWidgets,
          spans: state.dashboardWidgetSpans,
        ),
      ),
    );
    final density = DashboardDensityScope.of(context);
    final scale = DashboardDensityScope.scaleOf(context);
    final compact = density.isCompact;
    final order = [
      for (final widget in setting.widgets)
        if (widget.platforms.contains(platform)) widget,
    ];
    final spans = _decodeSpans(setting.spans);
    final rows = packDashboardRows(order, spans, columns);
    return LayoutBuilder(
      builder: (context, constraints) {
        final geometry = _geometry(constraints.maxWidth, columns, gap, scale);
        return SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(
            24 + geometry.inset,
            context.contentTopPadding,
            24 + geometry.inset,
            24 + MediaQuery.paddingOf(context).bottom,
          ),
          child: Column(
            spacing: gap,
            children: [
              for (final row in rows)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: gap,
                  children: [
                    for (final widget in row)
                      SizedBox(
                        width: geometry.spanWidth(
                          spans[widget]!.width.clamp(1, columns),
                          gap,
                        ),
                        height:
                            spans[widget]!.height.of(compact: compact) * scale,
                        child: RepaintBoundary(
                          key: cardKeyOf(widget),
                          child: widget.card,
                        ),
                      ),
                  ],
                ),
            ],
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
    required this.cardKeyOf,
    required this.onDone,
    required this.onCancel,
  });

  final SupportPlatform platform;
  final int columns;
  final double gap;
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
  late Map<DashboardWidget, DashboardSpan> _spans;

  @override
  void initState() {
    super.initState();
    final setting = ref.read(appSettingProvider);
    _order = [
      for (final item in setting.dashboardWidgets)
        if (item.platforms.contains(widget.platform)) item,
    ];
    _spans = _decodeSpans(setting.dashboardWidgetSpans);
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
              for (final entry in _spans.entries)
                entry.key.name: entry.key.spanCode(entry.value),
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
    setState(() {
      _order = [
        for (final item in platformDefaultDashboardWidgets)
          if (item.platforms.contains(widget.platform)) item,
      ];
      _spans = _decodeSpans(defaultDashboardWidgetSpans);
    });
  }

  void _reorder(DashboardWidget dragged, DashboardWidget target, bool after) {
    final list = [..._order]..remove(dragged);
    var index = list.indexOf(target);
    if (index == -1) {
      return;
    }
    if (after) {
      index++;
    }
    list.insert(index, dragged);
    setState(() => _order = list);
  }

  void _resizeWidth(DashboardWidget item, int direction) {
    final spec = item.spanSpec;
    final current = _spans[item]!;
    final index = spec.widths.indexOf(current.width);
    final next = (index + direction).clamp(0, spec.widths.length - 1);
    if (next != index) {
      setState(() {
        _spans = {
          ..._spans,
          item: DashboardSpan(width: spec.widths[next], height: current.height),
        };
      });
    }
  }

  void _resizeHeight(DashboardWidget item, int direction) {
    final spec = item.spanSpec;
    final current = _spans[item]!;
    final index = spec.heights.indexOf(current.height);
    final next = (index + direction).clamp(0, spec.heights.length - 1);
    if (next != index) {
      setState(() {
        _spans = {
          ..._spans,
          item: DashboardSpan(width: current.width, height: spec.heights[next]),
        };
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final density = DashboardDensityScope.of(context);
    final scale = DashboardDensityScope.scaleOf(context);
    final compact = density.isCompact;
    final appLocalizations = context.appLocalizations;
    final spans = _spans;
    final rows = packDashboardRows(_order, spans, widget.columns);
    final addable = [
      for (final item in DashboardWidget.values)
        if (item.platforms.contains(widget.platform) && !_order.contains(item))
          item,
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final geometry = _geometry(
          constraints.maxWidth,
          widget.columns,
          widget.gap,
          scale,
        );
        return SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(
            24 + geometry.inset,
            context.contentTopPadding,
            24 + geometry.inset,
            24 + MediaQuery.paddingOf(context).bottom,
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
              for (final row in rows)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: widget.gap,
                  children: [
                    for (final item in row)
                      _EditableCell(
                        item: item,
                        span: spans[item]!,
                        width: geometry.spanWidth(
                          spans[item]!.width.clamp(1, widget.columns),
                          widget.gap,
                        ),
                        height:
                            spans[item]!.height.of(compact: compact) * scale,
                        cardKey: widget.cardKeyOf(item),
                        onRemove: item.removable
                            ? () => setState(
                                () => _order = [..._order]..remove(item),
                              )
                            : null,
                        onResizeWidth: (direction) =>
                            _resizeWidth(item, direction),
                        onResizeHeight: (direction) =>
                            _resizeHeight(item, direction),
                        onReorder: _reorder,
                      ),
                  ],
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
}

class _EditableCell extends StatefulWidget {
  const _EditableCell({
    required this.item,
    required this.span,
    required this.width,
    required this.height,
    required this.cardKey,
    required this.onRemove,
    required this.onResizeWidth,
    required this.onResizeHeight,
    required this.onReorder,
  });

  final DashboardWidget item;
  final DashboardSpan span;
  final double width;
  final double height;
  final GlobalKey cardKey;
  final VoidCallback? onRemove;
  final ValueChanged<int> onResizeWidth;
  final ValueChanged<int> onResizeHeight;
  final void Function(
    DashboardWidget dragged,
    DashboardWidget target,
    bool after,
  )
  onReorder;

  @override
  State<_EditableCell> createState() => _EditableCellState();
}

class _EditableCellState extends State<_EditableCell> {
  bool _hoverAfter = false;
  bool _hovering = false;
  double _dragX = 0;
  double _dragY = 0;

  Widget _cardContent({required bool keyed}) {
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: AbsorbPointer(
        child: keyed
            ? RepaintBoundary(key: widget.cardKey, child: widget.item.card)
            : RepaintBoundary(child: widget.item.card),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final item = widget.item;
    final spec = item.spanSpec;
    final card = _cardContent(keyed: true);
    return DragTarget<DashboardWidget>(
      onWillAcceptWithDetails: (details) => details.data != item,
      onMove: (_) {
        if (!_hovering) {
          setState(() => _hovering = true);
        }
      },
      onLeave: (_) => setState(() => _hovering = false),
      onAcceptWithDetails: (details) {
        widget.onReorder(details.data, item, _hoverAfter);
        setState(() => _hovering = false);
      },
      builder: (context, _, _) => Listener(
        onPointerHover: (event) {
          final after = event.localPosition.dx > widget.width / 2;
          if (after != _hoverAfter) {
            setState(() => _hoverAfter = after);
          }
        },
        child: Stack(
          children: [
            LongPressDraggable<DashboardWidget>(
              data: item,
              feedback: Material(
                type: MaterialType.transparency,
                child: Opacity(
                  opacity: 0.85,
                  child: _cardContent(keyed: false),
                ),
              ),
              childWhenDragging: Opacity(
                opacity: 0.35,
                child: _cardContent(keyed: false),
              ),
              child: card,
            ),
            if (_hovering)
              PositionedDirectional(
                start: _hoverAfter ? null : 0,
                end: _hoverAfter ? 0 : null,
                top: 0,
                bottom: 0,
                child: Container(width: 3, color: colorScheme.primary),
              ),
            if (widget.onRemove != null)
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
                    onPressed: widget.onRemove,
                    icon: GlyphIcon(
                      AppGlyphs.remove,
                      size: 16,
                      color: colorScheme.onErrorContainer,
                    ),
                  ),
                ),
              ),
            if (spec.widths.length > 1)
              PositionedDirectional(
                end: 0,
                top: 0,
                bottom: 0,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragUpdate: (details) {
                    _dragX += details.delta.dx;
                    if (_dragX.abs() >= _resizeStep) {
                      widget.onResizeWidth(_dragX > 0 ? 1 : -1);
                      _dragX = 0;
                    }
                  },
                  child: SizedBox(
                    width: 14,
                    child: Center(
                      child: Container(
                        width: 4,
                        height: 36,
                        color: colorScheme.primary.withValues(alpha: 0.55),
                      ),
                    ),
                  ),
                ),
              ),
            if (spec.heights.length > 1)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragUpdate: (details) {
                    _dragY += details.delta.dy;
                    if (_dragY.abs() >= _resizeStep) {
                      widget.onResizeHeight(_dragY > 0 ? 1 : -1);
                      _dragY = 0;
                    }
                  },
                  child: SizedBox(
                    height: 14,
                    child: Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        color: colorScheme.primary.withValues(alpha: 0.55),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
