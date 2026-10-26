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
      expect(byWidget[DashboardWidget.currentOutbound]!.rows, 3);
      expect(byWidget[DashboardWidget.networkSpeed]!.column, 2);
      expect(byWidget[DashboardWidget.networkSpeed]!.row, 0);
      expect(byWidget[DashboardWidget.networkSpeed]!.rows, 3);
      expect(byWidget[DashboardWidget.outboundMode]!.column, 0);
      expect(byWidget[DashboardWidget.outboundMode]!.row, 3);
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

    test(
      'persisted resize changes one footprint without overlapping cards',
      () {
        final order = [
          DashboardWidget.currentOutbound,
          DashboardWidget.networkSpeed,
          DashboardWidget.outboundMode,
        ];
        final tiers = {for (final widget in order) widget: widget.tier};
        final normal = placeDashboardWidgets(order, tiers, 4);
        final resized = placeDashboardWidgets(
          order,
          tiers,
          4,
          spans: const {'currentOutbound': 42},
        );
        expect(normal.first.columns, 2);
        expect(resized.first.columns, 4);
        expect(resized.first.rows, 4);
        expect(resized[1].row, 4);
        final cells = <(int, int)>{};
        for (final item in resized) {
          for (var row = item.row; row < item.row + item.rows; row++) {
            for (
              var column = item.column;
              column < item.column + item.columns;
              column++
            ) {
              expect(cells.add((row, column)), isTrue);
            }
          }
        }
      },
    );
  });

  group('default tiers', () {
    test('each widget has a default tier, with a larger status hero', () {
      for (final widget in DashboardWidget.values) {
        expect(widget.tier, isNotNull, reason: '$widget');
      }
      expect(DashboardWidget.currentOutbound.tier, DashboardTier.mid);
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

      expect(height(DashboardTier.short), 100);
      expect(height(DashboardTier.mid), 156);
      expect(height(DashboardTier.narrow), 156);
      expect(height(DashboardTier.tall), 212);
      expect(height(DashboardTier.wide), 212);
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
