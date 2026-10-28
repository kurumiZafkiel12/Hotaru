import 'dart:math' as math;

import 'package:hotaru/enum/enum.dart';
import 'package:material_ui/material_ui.dart';

const _minDesktopWidth = 640.0;
const _minFourColumnWidth =
    DashboardLayoutTokens.pagePadding * 2 +
    DashboardLayoutTokens.minColumnWidth * 4 +
    dashboardGridGap * 3;
const _minStandardFourColumnWidth =
    DashboardLayoutTokens.pagePadding * 2 +
    DashboardLayoutTokens.comfortableColumnWidth * 4 +
    dashboardGridGap * 3;
const _minStandardHeight = 824.0;
const _mobileMaxWidth = 560.0;

int dashboardColumnsOf(double width) => width < _minFourColumnWidth ? 2 : 4;

abstract final class DashboardLayoutTokens {
  static const gap = 12.0;
  static const padding = 12.0;
  static const pagePadding = 16.0;
  static const desktopBaseHeight = 122.0;
  static const desktopHeightStep = 38.0;
  static const mobileBaseHeight = 118.0;
  static const mobileHeightStep = 32.0;
  static const minColumnWidth = 198.0;
  static const comfortableColumnWidth = 243.0;
  static const maxColumnWidth = 400.0;
}

enum DashboardBand {
  low,
  mid,
  high;

  double get height =>
      DashboardLayoutTokens.desktopBaseHeight +
      index * DashboardLayoutTokens.desktopHeightStep;

  double get mobileHeight =>
      DashboardLayoutTokens.mobileBaseHeight +
      index * DashboardLayoutTokens.mobileHeightStep;
}

const dashboardGridGap = DashboardLayoutTokens.gap;

class DashboardGridGeometry {
  DashboardGridGeometry({
    required double width,
    required this.columns,
    this.scale = 1,
    this.gap = dashboardGridGap,
    this.padding = DashboardLayoutTokens.pagePadding,
  }) : cellWidth = math.max(
         0,
         math.min(
           (width - padding * 2 - gap * (columns - 1)) / columns,
           DashboardLayoutTokens.maxColumnWidth * scale,
         ),
       );

  final int columns;
  final double scale;
  final double gap;
  final double padding;
  final double cellWidth;

  double get contentWidth => cellWidth * columns + gap * (columns - 1);

  Rect rectOf(DashboardPlacement placement) => Rect.fromLTWH(
    placement.column * (cellWidth + gap),
    placement.top,
    placement.columns * cellWidth + (placement.columns - 1) * gap,
    placement.height,
  );
}

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
