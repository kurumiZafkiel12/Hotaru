import 'package:hotaru/enum/enum.dart';
import 'package:hotaru/models/models.dart';
import 'package:hotaru/views/dashboard/layout.dart';
import 'package:hotaru/views/dashboard/widget_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('placeDashboardWidgets', () {
    test('interlocks tiers on the cell grid without overlaps', () {
      final order = [
        DashboardWidget.currentOutbound,
        DashboardWidget.networkSpeed,
        DashboardWidget.outboundMode,
        DashboardWidget.intranetIp,
        DashboardWidget.profiles,
      ];
      final tiers = {for (final widget in order) widget: widget.tier};
      final placements = placeDashboardWidgets(order, tiers, 4);
      final byWidget = {
        for (final placement in placements) placement.widget: placement,
      };
      expect(byWidget[DashboardWidget.currentOutbound]!.column, 0);
      expect(byWidget[DashboardWidget.currentOutbound]!.row, 0);
      expect(byWidget[DashboardWidget.currentOutbound]!.columns, 2);
      expect(byWidget[DashboardWidget.currentOutbound]!.rows, 1);
      expect(byWidget[DashboardWidget.networkSpeed]!.column, 2);
      expect(byWidget[DashboardWidget.networkSpeed]!.row, 0);
      expect(byWidget[DashboardWidget.networkSpeed]!.rows, 2);
      expect(byWidget[DashboardWidget.outboundMode]!.column, 0);
      expect(byWidget[DashboardWidget.outboundMode]!.row, 1);
      expect(byWidget[DashboardWidget.intranetIp]!.column, 0);
      expect(byWidget[DashboardWidget.intranetIp]!.row, 2);
      expect(byWidget[DashboardWidget.profiles]!.column, 1);
      expect(byWidget[DashboardWidget.profiles]!.row, 2);
      final cells = <int>{};
      for (final placement in placements) {
        for (var y = placement.row; y < placement.row + placement.rows; y++) {
          for (
            var x = placement.column;
            x < placement.column + placement.columns;
            x++
          ) {
            expect(cells.add(y * 4 + x), isTrue);
          }
        }
      }
    });

    test('clamps footprints wider than the grid', () {
      final order = [
        DashboardWidget.connectionsTable,
        DashboardWidget.currentOutbound,
      ];
      final tiers = {for (final widget in order) widget: widget.tier};
      final placements = placeDashboardWidgets(order, tiers, 2);
      expect(placements.first.columns, 2);
      expect(placements.first.rows, 2);
      expect(placements.last.row, 2);
      expect(placements.last.columns, 2);
    });
  });

  group('fixed tiers', () {
    test('every widget has exactly one fixed tier', () {
      for (final widget in DashboardWidget.values) {
        expect(widget.tier, isNotNull, reason: '$widget');
      }
      expect(DashboardWidget.currentOutbound.tier, DashboardTier.medium);
      expect(DashboardWidget.connectionsTable.tier, DashboardTier.wide);
      expect(DashboardTier.small.cells(4), (1, 1));
      expect(DashboardTier.medium.cells(4), (2, 1));
      expect(DashboardTier.large.cells(4), (2, 2));
      expect(DashboardTier.wide.cells(4), (4, 2));
    });
  });

  test('new widgets stay out of the default layout but remain addable', () {
    expect(defaultDashboardWidgets, isNot(contains(DashboardWidget.speedTest)));
    expect(
      defaultDashboardWidgets,
      isNot(contains(DashboardWidget.connectionsTable)),
    );
    expect(DashboardWidget.values, contains(DashboardWidget.speedTest));
    expect(DashboardWidget.values, contains(DashboardWidget.connectionsTable));
  });
}
