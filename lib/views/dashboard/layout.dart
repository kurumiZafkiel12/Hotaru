import 'dart:math' as math;

import 'package:hotaru/enum/enum.dart';
import 'package:material_ui/material_ui.dart';

const _minDesktopWidth = 640.0;
const _minFourColumnWidth = 860.0;
const _minStandardFourColumnWidth = 1040.0;
const _minStandardHeight = 824.0;
const _mobileMaxWidth = 560.0;

int dashboardColumnsOf(double width) => width < _minFourColumnWidth ? 2 : 4;

/// Height bands a desktop grid card can occupy; resize picks among the
/// bands a widget supports rather than stretching it freely.
enum DashboardCardHeight {
  hero,
  bar,
  summary,
  middle,
  large,
  tall,
  grande,

  /// The status card's compact default: below [hero], above [middle],
  /// whose compact band is too short for the card's rows.
  slimHero;

  double of({required bool compact}) => switch (this) {
    DashboardCardHeight.hero => compact ? 184 : 208,
    DashboardCardHeight.bar => compact ? 56 : 64,
    DashboardCardHeight.summary => compact ? 112 : 120,
    DashboardCardHeight.middle => compact ? 152 : 176,
    DashboardCardHeight.large => compact ? 216 : 232,
    DashboardCardHeight.tall => compact ? 288 : 320,
    DashboardCardHeight.grande => compact ? 432 : 480,
    DashboardCardHeight.slimHero => compact ? 164 : 188,
  };
}

/// The widths (in grid columns) and height bands one widget supports.
class DashboardSpanSpec {
  const DashboardSpanSpec({
    required this.widths,
    required this.defaultWidth,
    required this.heights,
    required this.defaultHeight,
  });

  final List<int> widths;
  final int defaultWidth;
  final List<DashboardCardHeight> heights;
  final DashboardCardHeight defaultHeight;
}

/// A widget's size in the desktop grid.
class DashboardSpan {
  const DashboardSpan({required this.width, required this.height});

  final int width;
  final DashboardCardHeight height;
}

/// Packs widgets into rows of at most [columns] columns, keeping order.
List<List<DashboardWidget>> packDashboardRows(
  List<DashboardWidget> order,
  Map<DashboardWidget, DashboardSpan> spans,
  int columns,
) {
  final rows = <List<DashboardWidget>>[];
  var row = <DashboardWidget>[];
  var used = 0;
  for (final widget in order) {
    final width = (spans[widget]?.width ?? 1).clamp(1, columns);
    if (row.isNotEmpty && used + width > columns) {
      rows.add(row);
      row = <DashboardWidget>[];
      used = 0;
    }
    row.add(widget);
    used += width;
  }
  if (row.isNotEmpty) {
    rows.add(row);
  }
  return rows;
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
