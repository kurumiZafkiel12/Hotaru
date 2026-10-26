import 'package:hotaru/enum/enum.dart';
import 'package:hotaru/models/models.dart';
import 'package:hotaru/views/dashboard/layout.dart';
import 'package:hotaru/views/dashboard/widget_registry.dart';
import 'package:flutter_test/flutter_test.dart';

DashboardSpan _span(
  DashboardWidget widget,
  int width,
  DashboardCardHeight height,
) => DashboardSpan(width: width, height: height);

void main() {
  group('packDashboardRows', () {
    test('packs widgets in order without exceeding the column count', () {
      final order = [
        DashboardWidget.currentOutbound,
        DashboardWidget.networkSpeed,
        DashboardWidget.outboundMode,
        DashboardWidget.intranetIp,
        DashboardWidget.profiles,
      ];
      final spans = {
        DashboardWidget.currentOutbound: _span(
          DashboardWidget.currentOutbound,
          4,
          DashboardCardHeight.hero,
        ),
        DashboardWidget.networkSpeed: _span(
          DashboardWidget.networkSpeed,
          2,
          DashboardCardHeight.middle,
        ),
        DashboardWidget.outboundMode: _span(
          DashboardWidget.outboundMode,
          2,
          DashboardCardHeight.bar,
        ),
        DashboardWidget.intranetIp: _span(
          DashboardWidget.intranetIp,
          1,
          DashboardCardHeight.middle,
        ),
        DashboardWidget.profiles: _span(
          DashboardWidget.profiles,
          1,
          DashboardCardHeight.middle,
        ),
      };
      final rows = packDashboardRows(order, spans, 4);
      expect(rows, [
        [DashboardWidget.currentOutbound],
        [DashboardWidget.networkSpeed, DashboardWidget.outboundMode],
        [DashboardWidget.intranetIp, DashboardWidget.profiles],
      ]);
    });

    test('clamps widths wider than the grid', () {
      final rows = packDashboardRows(
        [DashboardWidget.currentOutbound, DashboardWidget.networkSpeed],
        {
          DashboardWidget.currentOutbound: _span(
            DashboardWidget.currentOutbound,
            4,
            DashboardCardHeight.hero,
          ),
          DashboardWidget.networkSpeed: _span(
            DashboardWidget.networkSpeed,
            2,
            DashboardCardHeight.middle,
          ),
        },
        2,
      );
      expect(rows, [
        [DashboardWidget.currentOutbound],
        [DashboardWidget.networkSpeed],
      ]);
    });
  });

  group('span persistence', () {
    test('every widget has a valid default span', () {
      for (final widget in DashboardWidget.values) {
        final span = widget.spanFrom(const {});
        expect(widget.spanSpec.widths, contains(span.width), reason: '$widget');
        expect(
          widget.spanSpec.heights,
          contains(span.height),
          reason: '$widget',
        );
      }
    });

    test('span codes round-trip through the persisted map', () {
      for (final widget in DashboardWidget.values) {
        final spec = widget.spanSpec;
        final span = DashboardSpan(
          width: spec.widths.last,
          height: spec.heights.last,
        );
        final restored = widget.spanFrom({widget.name: widget.spanCode(span)});
        expect(restored.width, span.width, reason: '$widget');
        expect(restored.height, span.height, reason: '$widget');
      }
    });

    test('invalid codes fall back to the spec defaults', () {
      final span = DashboardWidget.networkSpeed.spanFrom({'networkSpeed': 99});
      expect(span.width, DashboardWidget.networkSpeed.spanSpec.defaultWidth);
      expect(span.height, DashboardWidget.networkSpeed.spanSpec.defaultHeight);
    });

    test('shipped default span codes decode to valid spans', () {
      for (final entry in defaultDashboardWidgetSpans.entries) {
        final widget = DashboardWidget.values.asNameMap()[entry.key];
        expect(widget, isNotNull, reason: entry.key);
        final span = widget!.spanFrom(defaultDashboardWidgetSpans);
        expect(widget.spanSpec.widths, contains(span.width), reason: entry.key);
      }
    });
  });

  test(
    'the status card resizes in width and height from a compact default',
    () {
      final spec = DashboardWidget.currentOutbound.spanSpec;
      expect(spec.widths, [2, 3, 4]);
      expect(spec.heights, [
        DashboardCardHeight.slimHero,
        DashboardCardHeight.hero,
        DashboardCardHeight.large,
      ]);
      final span = DashboardWidget.currentOutbound.spanFrom(const {});
      expect(span.width, 4);
      expect(span.height, DashboardCardHeight.slimHero);
      // Codes shipped before the unlock keep working: 40 was full width.
      final shipped = DashboardWidget.currentOutbound.spanFrom(const {
        'currentOutbound': 40,
      });
      expect(shipped.width, 4);
      expect(shipped.height, DashboardCardHeight.slimHero);
    },
  );

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
