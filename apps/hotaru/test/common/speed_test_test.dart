import 'package:hotaru/common/speed_test.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('speedGaugeScaleMax', () {
    test('picks the first tier that contains the value', () {
      expect(speedGaugeScaleMax(0), 10 * 1e6);
      expect(speedGaugeScaleMax(8 * 1e6), 10 * 1e6);
      expect(speedGaugeScaleMax(10 * 1e6), 10 * 1e6);
      expect(speedGaugeScaleMax(42 * 1e6), 50 * 1e6);
      expect(speedGaugeScaleMax(300 * 1e6), 500 * 1e6);
      expect(speedGaugeScaleMax(950 * 1e6), 1000 * 1e6);
    });

    test('caps at the top tier for very fast links', () {
      expect(speedGaugeScaleMax(9000 * 1e6), 10000 * 1e6);
      expect(speedGaugeScaleMax(50000 * 1e6), 10000 * 1e6);
    });
  });

  group('speedNeedleFraction', () {
    test('sits at the marks and between them', () {
      expect(speedNeedleFraction(0), 0);
      expect(speedNeedleFraction(5 * 1e6), closeTo(1 / 8, 0.001));
      expect(speedNeedleFraction(7.5 * 1e6), closeTo(1.5 / 8, 0.001));
      expect(speedNeedleFraction(50 * 1e6), closeTo(3 / 8, 0.001));
      expect(speedNeedleFraction(750 * 1e6), closeTo(7 / 8, 0.001));
      expect(speedNeedleFraction(1000 * 1e6), 1);
    });

    test('clamps past the top of the dial', () {
      expect(speedNeedleFraction(4000 * 1e6), 1);
    });
  });

  test('every provider has a distinct label', () {
    final labels = SpeedTestProvider.values.map((p) => p.label).toSet();
    expect(labels.length, SpeedTestProvider.values.length);
    expect(
      labels,
      containsAll([
        'Apple',
        'Cloudflare',
        'Speedtest',
        'Fast.com',
        'LibreSpeed',
      ]),
    );
  });
}
