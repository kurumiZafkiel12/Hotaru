import 'package:hotaru/enum/enum.dart';
import 'package:hotaru/models/models.dart';
import 'package:hotaru/views/dashboard/layout.dart';
import 'package:hotaru/views/dashboard/widget_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('desktop cards use only the three fixed logical heights', () {
    expect(DashboardTier.short.height, 122);
    expect(DashboardTier.mid.height, 160);
    expect(DashboardTier.tall.height, 198);
    for (final tier in DashboardTier.values) {
      expect(tier.height, anyOf(122, 160, 198));
    }
  });

  test('column boundaries and gaps remain regular after reordering', () {
    for (final columns in [2, 4]) {
      for (final order in [
        DashboardWidget.values,
        DashboardWidget.values.reversed.toList(),
      ]) {
        final result = placeDashboardWidgets(order, {
          for (final item in order) item: item.tier,
        }, columns);
        expect(result, hasLength(order.length));
        for (final item in result) {
          expect(item.column, greaterThanOrEqualTo(0));
          expect(item.column + item.columns, lessThanOrEqualTo(columns));
          expect(item.height, anyOf(122, 160, 198));
          for (final other in result) {
            if (identical(item, other)) continue;
            final sameColumns =
                item.column < other.column + other.columns &&
                other.column < item.column + item.columns;
            if (sameColumns) {
              expect(
                item.top >= other.bottom + 12 || other.top >= item.bottom + 12,
                isTrue,
              );
            }
          }
        }
      }
    }
  });

  test('two primary cards retain equal fixed heights and aligned columns', () {
    final order = [
      DashboardWidget.currentOutbound,
      DashboardWidget.networkSpeed,
    ];
    final tiers = {for (final item in order) item: item.tier};
    final result = placeDashboardWidgets(order, tiers, 4);
    expect(result.first.columns, 2);
    expect(result.first.height, 160);
    expect(result.last.top, 0);
    expect(result.last.column, 2);
  });

  test('the statistics summary uses one column at the fixed low height', () {
    final order = [
      DashboardWidget.currentOutbound,
      DashboardWidget.networkSpeed,
      DashboardWidget.outboundMode,
      DashboardWidget.networkTakeover,
      DashboardWidget.connectionStats,
    ];
    final result = placeDashboardWidgets(order, {
      for (final item in order) item: item.tier,
    }, 4);
    expect(result[0].top, result[1].top);
    expect(result[2].top, result[3].top);
    expect(result[0].column, result[2].column);
    expect(result[1].column, result[3].column);
    expect(result.last.columns, 1);
    expect(result.last.height, 122);
    expect(result.last.top, 306);
  });

  test('summary and optional table leave room for neighboring cards', () {
    final order = [
      DashboardWidget.connectionStats,
      DashboardWidget.connectionsTable,
      DashboardWidget.profiles,
    ];
    final result = placeDashboardWidgets(order, {
      for (final item in order) item: item.tier,
    }, 4);
    expect(result[0].height, 122);
    expect(result[0].columns, 1);
    expect(result[1].columns, 2);
    expect(result[1].top, 0);
    expect(result[2].columns, 1);
    expect(result[2].top, 0);
  });

  test('full-width tables stack without overlapping the next card', () {
    final order = [
      DashboardWidget.connectionsTable,
      DashboardWidget.currentOutbound,
    ];
    final result = placeDashboardWidgets(order, {
      for (final item in order) item: item.tier,
    }, 2);
    expect(result.first.columns, 2);
    expect(result.first.height, 198);
    expect(result.last.top, 210);
  });

  test(
    'optional tools remain addable without crowding the initial dashboard',
    () {
      expect(
        defaultDashboardWidgets,
        isNot(contains(DashboardWidget.speedTest)),
      );
      expect(
        defaultDashboardWidgets,
        isNot(contains(DashboardWidget.connectionsTable)),
      );
      expect(
        DashboardWidget.values,
        contains(DashboardWidget.connectionsTable),
      );
    },
  );
}
