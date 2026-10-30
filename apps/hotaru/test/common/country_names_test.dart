import 'package:hotaru/common/country_names.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'country display names are localized independently of IP attributes',
    () {
      expect(countryName('JP', 'zh'), '日本');
      expect(countryName('GB', 'en'), 'United Kingdom');
      expect(countryName('DE', 'ja'), 'ドイツ');
      expect(countryName('US', 'fr'), 'États-Unis');
      expect(countryName('SG', 'es'), 'Singapur');
      expect(countryName('GB', 'ru'), 'Великобритания');
      expect(countryName('JP', 'ko'), '일본');
    },
  );

  test(
    'every two-letter CLDR territory uses the language fallback consistently',
    () {
      var named = 0;
      for (var first = 65; first <= 90; first++) {
        for (var last = 65; last <= 90; last++) {
          final code = String.fromCharCodes([first, last]);
          if (countryName(code, 'en') != null) {
            named++;
            for (final language in ['zh', 'ja', 'ru', 'fr', 'es', 'ko']) {
              expect(
                countryName(code, language),
                isNotEmpty,
                reason: '$code/$language',
              );
            }
          }
        }
      }
      expect(named, greaterThanOrEqualTo(249));
      expect(countryName(' jp ', 'zh'), '日本');
      expect(countryName('JP', 'unavailable'), 'Japan');
      expect(countryName(null, 'en'), isNull);
      expect(countryName('ZZ', 'en'), isNull);
      expect(countryName('invalid', 'en'), isNull);
    },
  );
}
