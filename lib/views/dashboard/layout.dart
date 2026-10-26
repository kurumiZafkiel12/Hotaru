import 'dart:math' as math;

import 'package:hotaru/enum/enum.dart';
import 'package:material_ui/material_ui.dart';

const _minDesktopWidth = 640.0;
const _minFourColumnWidth = 860.0;
const _minStandardFourColumnWidth = 1040.0;
const _minStandardHeight = 824.0;
const _mobileMaxWidth = 560.0;

int dashboardColumnsOf(double width) => width < _minFourColumnWidth ? 2 : 4;

enum DashboardTier {
  narrow,
  short,
  mid,
  tall,
  wide;

  /// The tier's footprint in grid cells at [columns] columns.
  (int, int) cells(int columns) => switch (this) {
    DashboardTier.narrow => (1, 3),
    DashboardTier.short => (2, 2),
    DashboardTier.mid => (2, 3),
    DashboardTier.tall => (2, 4),
    DashboardTier.wide => (columns, 4),
  };
}

/// The height of one grid unit; a card spanning n units is
/// n units plus the gaps between them tall.
double dashboardUnitHeight({required bool compact}) => compact ? 40 : 44;

/// Where one card lands in the cell grid.
class DashboardPlacement {
  const DashboardPlacement({
    required this.widget,
    required this.column,
    required this.row,
    required this.columns,
    required this.rows,
  });

  final DashboardWidget widget;
  final int column;
  final int row;
  final int columns;
  final int rows;
}

/// First-fit packing over the cell grid, keeping the user's order: each
/// card takes the earliest free block of its tier's cells, so cards
/// interlock with one uniform gap and no ragged seams.
List<DashboardPlacement> placeDashboardWidgets(
  List<DashboardWidget> order,
  Map<DashboardWidget, DashboardTier> tiers,
  int columns, {
  Map<String, int> spans = const {},
}) {
  final occupied = <int>{};
  final placements = <DashboardPlacement>[];
  for (final widget in order) {
    final tier = tiers[widget] ?? DashboardTier.mid;
    final fallback = tier.cells(columns);
    final span = spans[widget.name];
    final (wantColumns, wantRows) = span == null
        ? fallback
        : ((span ~/ 10).clamp(1, columns), 2 + (span % 10).clamp(0, 2));
    final width = math.min(
      math.max(wantColumns, tier == DashboardTier.narrow ? 1 : 2),
      columns,
    );
    final rows = math.max(wantRows, fallback.$2);
    var row = 0;
    while (true) {
      var placed = false;
      for (var column = 0; column + width <= columns; column++) {
        var free = true;
        for (var y = row; y < row + rows && free; y++) {
          for (var x = column; x < column + width; x++) {
            if (occupied.contains(y * columns + x)) {
              free = false;
              break;
            }
          }
        }
        if (free) {
          for (var y = row; y < row + rows; y++) {
            for (var x = column; x < column + width; x++) {
              occupied.add(y * columns + x);
            }
          }
          placements.add(
            DashboardPlacement(
              widget: widget,
              column: column,
              row: row,
              columns: width,
              rows: rows,
            ),
          );
          placed = true;
          break;
        }
      }
      if (placed) {
        break;
      }
      row++;
    }
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
