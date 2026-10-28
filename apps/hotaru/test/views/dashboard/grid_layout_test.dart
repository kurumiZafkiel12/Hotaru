import 'package:hotaru/enum/enum.dart';
import 'package:hotaru/models/models.dart';
import 'package:hotaru/views/dashboard/layout.dart';
import 'package:hotaru/views/dashboard/widget_registry.dart';
import 'package:flutter_test/flutter_test.dart';

Map<DashboardWidget, DashboardBand> _bandsOf(List<DashboardWidget> order) => {
  for (final widget in order) widget: widget.band,
};

Map<DashboardWidget, int> _widthsOf(List<DashboardWidget> order) => {
  for (final widget in order) widget: widget.span,
};

void main() {
  test('grid geometry keeps all column edges aligned across window sizes', () {
    for (final width in [320.0, 640.0, 860.0, 1040.0, 1440.0, 2560.0]) {
      final columns = dashboardColumnsOf(width);
      final geometry = DashboardGridGeometry(width: width, columns: columns);
      final placements = placeDashboardWidgets(
        [
          DashboardWidget.currentOutbound,
          DashboardWidget.networkSpeed,
          DashboardWidget.outboundMode,
          DashboardWidget.networkTakeover,
        ],
        _bandsOf(DashboardWidget.values),
        _widthsOf(DashboardWidget.values),
        columns,
      );
      for (final placement in placements) {
        final rect = geometry.rectOf(placement);
        expect(
          rect.left,
          placement.column * (geometry.cellWidth + dashboardGridGap),
        );
        expect(rect.right, lessThanOrEqualTo(geometry.contentWidth + 0.01));
      }
      expect(
        geometry.contentWidth,
        lessThanOrEqualTo(width - geometry.padding * 2),
      );
    }
  });

  test('mobile height scale is independent and preserves a regular rhythm', () {
    expect(DashboardBand.low.mobileHeight, 118);
    expect(DashboardBand.mid.mobileHeight - DashboardBand.low.mobileHeight, 32);
    expect(
      DashboardBand.high.mobileHeight - DashboardBand.mid.mobileHeight,
      32,
    );
    expect(DashboardWidget.currentOutbound.mobileBand, DashboardBand.mid);
    expect(
      DashboardWidget.currentOutbound.mobileBandFor(320, hasAddress: false),
      DashboardBand.low,
    );
    expect(
      DashboardWidget.currentOutbound.mobileBandFor(320),
      DashboardBand.high,
    );
    expect(
      DashboardWidget.currentOutbound.mobileBandFor(390),
      DashboardBand.mid,
    );
    for (final band in DashboardBand.values) {
      expect(band.mobileHeight, lessThan(band.height));
    }
  });

  group('placeDashboardWidgets', () {
    test('interlocks bands without overlaps and keeps one uniform gap', () {
      final order = [
        DashboardWidget.currentOutbound,
        DashboardWidget.networkSpeed,
        DashboardWidget.outboundMode,
        DashboardWidget.intranetIp,
        DashboardWidget.profiles,
      ];
      final placements = placeDashboardWidgets(
        order,
        _bandsOf(order),
        _widthsOf(order),
        4,
      );
      final byWidget = {
        for (final placement in placements) placement.widget: placement,
      };
      expect(byWidget[DashboardWidget.currentOutbound]!.column, 0);
      expect(byWidget[DashboardWidget.currentOutbound]!.top, 0);
      expect(byWidget[DashboardWidget.currentOutbound]!.columns, 2);
      expect(byWidget[DashboardWidget.currentOutbound]!.height, 122);
      expect(byWidget[DashboardWidget.networkSpeed]!.column, 2);
      expect(byWidget[DashboardWidget.networkSpeed]!.top, 0);
      expect(byWidget[DashboardWidget.networkSpeed]!.height, 160);
      expect(byWidget[DashboardWidget.outboundMode]!.column, 0);
      expect(
        byWidget[DashboardWidget.outboundMode]!.top,
        122 + dashboardGridGap,
      );
      for (final a in placements) {
        for (final b in placements) {
          if (a == b) continue;
          final columnsOverlap =
              a.column < b.column + b.columns &&
              b.column < a.column + a.columns;
          if (!columnsOverlap) continue;
          final separated =
              a.bottom + dashboardGridGap <= b.top ||
              b.bottom + dashboardGridGap <= a.top;
          expect(separated, isTrue, reason: '${a.widget} vs ${b.widget}');
        }
      }
    });

    test('column edges stay on the grid across the full widget set', () {
      final order = [...DashboardWidget.values];
      final placements = placeDashboardWidgets(
        order,
        _bandsOf(order),
        _widthsOf(order),
        4,
      );
      expect(placements, hasLength(order.length));
      for (final placement in placements) {
        expect(placement.column + placement.columns, lessThanOrEqualTo(4));
        expect(placement.top, greaterThanOrEqualTo(0));
      }
    });

    test('clamps footprints wider than the grid', () {
      final order = [
        DashboardWidget.connectionsTable,
        DashboardWidget.currentOutbound,
      ];
      final placements = placeDashboardWidgets(
        order,
        _bandsOf(order),
        _widthsOf(order),
        2,
      );
      expect(placements.first.columns, 2);
      expect(placements.first.height, 198);
      expect(placements.last.top, 198 + dashboardGridGap);
      expect(placements.last.columns, 2);
    });

    test('text scale grows card heights and pushes later cards down', () {
      final order = [
        DashboardWidget.currentOutbound,
        DashboardWidget.outboundMode,
      ];
      final placements = placeDashboardWidgets(
        order,
        _bandsOf(order),
        _widthsOf(order),
        2,
        scale: 1.5,
      );
      expect(placements.first.height, 122 * 1.5);
      expect(placements.last.top, 122 * 1.5 + dashboardGridGap);
    });
  });

  group('default bands', () {
    test('each widget has a fixed band and span from the spec', () {
      for (final widget in DashboardWidget.values) {
        expect(widget.band, isNotNull, reason: '$widget');
        expect(widget.span, inInclusiveRange(1, 4), reason: '$widget');
      }
      expect(DashboardWidget.currentOutbound.band, DashboardBand.low);
      expect(DashboardWidget.networkSpeed.band, DashboardBand.mid);
      expect(DashboardWidget.networkTakeover.band, DashboardBand.low);
      expect(DashboardWidget.proxyGroups.band, DashboardBand.high);
      expect(DashboardWidget.connectionsTable.band, DashboardBand.high);
      expect(DashboardWidget.connectionsTable.span, 4);
      expect(DashboardWidget.intranetIp.band, DashboardBand.low);
      expect(DashboardWidget.intranetIp.span, 1);
      expect(DashboardWidget.serviceStatus.band, DashboardBand.mid);
      expect(DashboardWidget.memoryInfo.band, DashboardBand.mid);
    });

    test('band heights are the three spec heights', () {
      expect(DashboardBand.low.height, 122);
      expect(DashboardBand.mid.height, 160);
      expect(DashboardBand.high.height, 198);
      expect(dashboardGridGap, 12);
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
