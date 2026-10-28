import 'dart:math' as math;

import 'package:hotaru/enum/enum.dart';
import 'package:material_ui/material_ui.dart';

const _minDesktopWidth = 640.0;
const _minFourColumnWidth = 860.0;
const _minStandardFourColumnWidth = 1040.0;
const _minStandardHeight = 824.0;
const _mobileMaxWidth = 560.0;

int dashboardColumnsOf(double width) => width < _minFourColumnWidth ? 2 : 4;

abstract final class DashboardSizing {
  static const gap = 12.0;
  static const inset = 12.0;
  static const low = 122.0;
  static const step = 38.0;
  static const maxColumn = 320.0;
  static const desktopControlHeight = 32.0;
  static const desktopStartButton = 56.0;
  static const desktopSwitchScale = 0.875;

  static double height(int level) => low + step * level;
}

enum DashboardTier {
  narrow,
  short,
  mid,
  tall,
  wide,
  strip;

  int columns(int available) => switch (this) {
    narrow => 1,
    wide || strip => available,
    _ => math.min(2, available),
  };

  double get height => DashboardSizing.height(switch (this) {
    short || strip => 0,
    narrow || mid => 1,
    tall || wide => 2,
  });
}

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
  final double height;
  double get bottom => top + height;
}

List<DashboardPlacement> placeDashboardWidgets(
  List<DashboardWidget> order,
  Map<DashboardWidget, DashboardTier> tiers,
  int columns,
) {
  final result = <DashboardPlacement>[];
  for (final widget in order) {
    final tier = tiers[widget] ?? DashboardTier.mid;
    final width = tier.columns(columns);
    final candidates = {
      0.0,
      for (final item in result) item.bottom + DashboardSizing.gap,
    }.toList()..sort();
    DashboardPlacement? selected;
    for (final top in candidates) {
      for (var column = 0; column <= columns - width; column++) {
        final occupied = result.any(
          (item) =>
              item.column < column + width &&
              column < item.column + item.columns &&
              item.top < top + tier.height + DashboardSizing.gap &&
              top < item.bottom + DashboardSizing.gap,
        );
        if (occupied) continue;
        selected = DashboardPlacement(
          widget: widget,
          column: column,
          top: top,
          columns: width,
          height: tier.height,
        );
        break;
      }
      if (selected != null) break;
    }
    result.add(selected!);
  }
  return result;
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

/// Text metrics are separate from the fixed desktop height bands.
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
