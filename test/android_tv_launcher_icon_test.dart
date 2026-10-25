import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

String _androidAttribute(String source, String element, String attribute) {
  final elementTag = RegExp('<$element\\b[^>]*>').firstMatch(source)!.group(0)!;
  return RegExp(
    'android:$attribute="([^"]+)"',
  ).firstMatch(elementTag)!.group(1)!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('TV launcher icons meet density-specific minimum sizes', () async {
    // The rebrand ships shared Hotaru PNGs instead of density-exact
    // webp files, so each density must clear its old minimum size.
    const minimumSizes = {
      'mdpi': 80,
      'hdpi': 120,
      'xhdpi': 160,
      'xxhdpi': 240,
      'xxxhdpi': 320,
    };

    for (final MapEntry(key: density, value: size) in minimumSizes.entries) {
      final file = File(
        'android/app/src/main/res/'
        'mipmap-television-$density/ic_launcher.png',
      );
      expect(file.existsSync(), isTrue, reason: 'missing ${file.path}');

      final codec = await ui.instantiateImageCodec(await file.readAsBytes());
      final frame = await codec.getNextFrame();
      expect(frame.image.width, greaterThanOrEqualTo(size), reason: file.path);
      expect(frame.image.height, greaterThanOrEqualTo(size), reason: file.path);
      expect(frame.image.width, frame.image.height, reason: file.path);
      frame.image.dispose();
      codec.dispose();
    }
  });

  test('TV adaptive launcher icon references the Hotaru foreground', () {
    final adaptiveIcon = File(
      'android/app/src/main/res/'
      'mipmap-television-anydpi-v26/ic_launcher.xml',
    ).readAsStringSync();
    expect(
      _androidAttribute(adaptiveIcon, 'foreground', 'drawable'),
      '@drawable/ic_launcher_foreground_tv',
    );
    expect(
      _androidAttribute(adaptiveIcon, 'background', 'drawable'),
      '@color/ic_launcher_background',
    );

    // The foreground is a full Hotaru PNG now, not a vector logo, so
    // there is no vector transform left to check against a safe zone.
    final foreground = File(
      'android/app/src/main/res/drawable/ic_launcher_foreground_tv.png',
    );
    expect(foreground.existsSync(), isTrue);
  });
}
