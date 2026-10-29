import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:hotaru/ui/speed_dial.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'the visible needle follows every measured fraction, including zero',
    () async {
      for (final fraction in [0.0, 0.25, 0.5, 0.75, 1.0]) {
        final recorder = ui.PictureRecorder();
        SpeedDialPainter(
          fraction: fraction,
          trackColor: Colors.transparent,
          valueColor: const Color(0xff00ff00),
          glowColor: Colors.transparent,
        ).paint(Canvas(recorder), const Size.square(288));
        final picture = recorder.endRecording();
        final image = await picture.toImage(288, 288);
        final pixels = (await image.toByteData())!.buffer.asUint8List();
        final angle = math.pi * 0.75 + math.pi * 1.5 * fraction;
        final x = (144 + math.cos(angle) * 50).round();
        final y = (144 + math.sin(angle) * 50).round();
        final index = (y * 288 + x) * 4;
        expect(
          pixels[index + 1],
          greaterThan(200),
          reason: 'needle at $fraction',
        );
        expect(pixels[index + 3], greaterThan(100));
        image.dispose();
        picture.dispose();
      }
    },
  );
}
