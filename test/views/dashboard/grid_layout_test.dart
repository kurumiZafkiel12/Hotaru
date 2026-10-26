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
      expect(byWidget[DashboardWidget.currentOutbound]!.rows, 2);
      expect(byWidget[DashboardWidget.networkSpeed]!.column, 2);
      expect(byWidget[DashboardWidget.networkSpeed]!.row, 0);
      expect(byWidget[DashboardWidget.networkSpeed]!.rows, 3);
      expect(byWidget[DashboardWidget.outboundMode]!.column, 0);
      expect(byWidget[DashboardWidget.outboundMode]!.row, 2);
      expect(byWidget[DashboardWidget.intranetIp]!.column, 2);
      expect(byWidget[DashboardWidget.intranetIp]!.row, 3);
      expect(byWidget[DashboardWidget.profiles]!.column, 3);
      expect(byWidget[DashboardWidget.profiles]!.row, 3);
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
      expect(placements.first.rows, 4);
      expect(placements.last.row, 4);
      expect(placements.last.columns, 2);
    });
  });

  group('fixed tiers', () {
    test('every widget has exactly one fixed tier', () {
      for (final widget in DashboardWidget.values) {
        expect(widget.tier, isNotNull, reason: '$widget');
      }
      expect(DashboardWidget.currentOutbound.tier, DashboardTier.short);
      expect(DashboardWidget.connectionsTable.tier, DashboardTier.wide);
      expect(DashboardTier.narrow.cells(4), (1, 3));
      expect(DashboardTier.short.cells(4), (2, 2));
      expect(DashboardTier.mid.cells(4), (2, 3));
      expect(DashboardTier.tall.cells(4), (2, 4));
      expect(DashboardTier.wide.cells(4), (4, 4));
    });

    test('tier heights land on the three compact bands', () {
      double height(DashboardTier tier) {
        final rows = tier.cells(4).$2;
        const gap = 12.0;
        return rows * dashboardUnitHeight(compact: false) + (rows - 1) * gap;
      }

      expect(height(DashboardTier.short), 122);
      expect(height(DashboardTier.mid), 189);
      expect(height(DashboardTier.narrow), 189);
      expect(height(DashboardTier.tall), 256);
      expect(height(DashboardTier.wide), 256);
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
