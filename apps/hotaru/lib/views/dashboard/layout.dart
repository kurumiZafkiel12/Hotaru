import 'dart:math' as math;

import 'package:hotaru/enum/enum.dart';
import 'package:material_ui/material_ui.dart';

const _minDesktopWidth = 640.0;
const _minFourColumnWidth = 860.0;
const _minStandardFourColumnWidth = 1040.0;
const _minStandardHeight = 824.0;
const _mobileMaxWidth = 560.0;

int dashboardColumnsOf(double width) => width < _minFourColumnWidth ? 2 : 4;

/// The three fixed card heights of the dashboard spec. A card's band is a
/// property of the widget, never of the user's layout: cards are dragged
/// to reorder, never resized.
enum DashboardBand {
  low,
  mid,
  high;

  double get height => switch (this) {
    DashboardBand.low => 122,
    DashboardBand.mid => 160,
    DashboardBand.high => 198,
  };

  /// Phones run their own, slightly taller bands: the mobile card
  /// bodies keep roomier touch metrics than the desktop ones, while
  /// the grid still fixes every card's height so a screenful shows
  /// several cards instead of two or three full-width slabs.
  double get mobileHeight => switch (this) {
    DashboardBand.low => 148,
    DashboardBand.mid => 188,
    DashboardBand.high => 230,
  };
}

/// The one gap between dashboard cards, everywhere in the grid.
const dashboardGridGap = 12.0;

/// Where one card lands in the grid: a column span and an exact top, so
/// cards stacked in a column sit exactly one gap apart, and every
/// column edge lines up across the whole page.
class DashboardPlacement {
  const DashboardPlacement({
    required this.widget,
    required this.column,
    required this.top,
    required this.columns,
    required this.height,
  });

  final DashboardWidget widget;
  final int column;
  final double top;
  final int columns;

  /// The card's own height: its band height at the current text scale.
  final double height;

  double get bottom => top + height;
}

/// First-fit packing, keeping the user's order: each card takes the
/// highest, then leftmost, free span of columns at its band's height,
/// so cards interlock with one uniform gap and no ragged seams.
List<DashboardPlacement> placeDashboardWidgets(
  List<DashboardWidget> order,
  Map<DashboardWidget, DashboardBand> bands,
  Map<DashboardWidget, int> widths,
  int columns, {
  double scale = 1,
  double Function(DashboardBand band)? bandHeight,
}) {
  final heightOfBand = bandHeight ?? (band) => band.height;
  final placements = <DashboardPlacement>[];
  for (final widget in order) {
    final band = bands[widget] ?? DashboardBand.mid;
    final width = math.min(math.max(widths[widget] ?? 2, 1), columns);
    final height = heightOfBand(band) * scale;
    final tops = <double>{
      0,
      for (final placed in placements) placed.bottom + dashboardGridGap,
    }.toList()..sort();
    DashboardPlacement? spot;
    for (final top in tops) {
      for (
        var column = 0;
        column + width <= columns && spot == null;
        column++
      ) {
        final blocked = placements.any(
          (placed) =>
              column < placed.column + placed.columns &&
              placed.column < column + width &&
              top < placed.bottom + dashboardGridGap &&
              placed.top < top + height + dashboardGridGap,
        );
        if (!blocked) {
          spot = DashboardPlacement(
            widget: widget,
            column: column,
            top: top,
            columns: width,
            height: height,
          );
        }
      }
      if (spot != null) {
        break;
      }
    }
    placements.add(spot!);
  }
  return placements;
}

/// The mobile cards and their editor share one centered column.
double dashboardMobileSideOf(double width) =>
    math.max(16, (width - _mobileMaxWidth) / 2);

/// [compact] shrinks type, the start button and tiles, and drops subtitles.
enum DashboardDensity {
  standard,
  compact,
  mobile;

  bool get isDesktop => this != mobile;

  bool get isCompact => this == compact;

  static DashboardDensity of(Size size) {
    if (size.width < _minDesktopWidth) {
      return mobile;
    }
    final narrowColumns =
        dashboardColumnsOf(size.width) == 4 &&
        size.width < _minStandardFourColumnWidth;
    return narrowColumns || size.height < _minStandardHeight
        ? compact
        : standard;
  }
}

/// Every fixed height on the dashboard grows by [scale] so its text fits.
class DashboardDensityScope extends InheritedWidget {
  const DashboardDensityScope({
    super.key,
    required this.density,
    required this.scale,
    required super.child,
  });

  final DashboardDensity density;
  final double scale;

  static DashboardDensityScope? _of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DashboardDensityScope>();

  static DashboardDensity of(BuildContext context) =>
      _of(context)?.density ?? DashboardDensity.mobile;

  static double scaleOf(BuildContext context) => _of(context)?.scale ?? 1;

  @override
  bool updateShouldNotify(DashboardDensityScope oldWidget) =>
      density != oldWidget.density || scale != oldWidget.scale;
}
