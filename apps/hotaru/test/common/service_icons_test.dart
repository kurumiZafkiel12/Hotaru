import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/common/service_probe.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  test('all services have a bundled dedicated icon', () {
    expect(ServiceTarget.values.length, 63);
    for (final target in ServiceTarget.values) {
      expect(target.icon, isNotEmpty, reason: target.id);
      expect(
        File('assets/images/services/${target.icon}.svg').existsSync(),
        isTrue,
        reason: target.id,
      );
    }
  });

  for (final dark in [true, false]) {
    testWidgets(
      'all service icons render visibly on ${dark ? 'dark' : 'light'} surfaces',
      (tester) async {
        const cell = 40.0;
        const columns = 8;
        final key = GlobalKey();
        final background = dark
            ? const Color(0xff111317)
            : const Color(0xfff5f5f5);
        final ink = dark ? const Color(0xff34d399) : const Color(0xff166534);
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: RepaintBoundary(
                key: key,
                child: SizedBox.square(
                  dimension: cell * columns,
                  child: ColoredBox(
                    color: background,
                    child: Wrap(
                      children: [
                        for (final target in ServiceTarget.values)
                          SizedBox.square(
                            dimension: cell,
                            child: Center(
                              child: SvgPicture.asset(
                                'assets/images/services/${target.icon}.svg',
                                width: 32,
                                height: 32,
                                theme: SvgTheme(currentColor: ink),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          try {
            final bytes = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!;
            final value = background.toARGB32();
            final rgb = [(value >> 16) & 255, (value >> 8) & 255, value & 255];
            for (var index = 0; index < ServiceTarget.values.length; index++) {
              final x = (index % columns) * cell.toInt();
              final y = (index ~/ columns) * cell.toInt();
              var visible = 0;
              for (var row = y; row < y + cell; row++) {
                for (var column = x; column < x + cell; column++) {
                  final offset = (row * image.width + column) * 4;
                  final difference =
                      (bytes.getUint8(offset) - rgb[0]).abs() +
                      (bytes.getUint8(offset + 1) - rgb[1]).abs() +
                      (bytes.getUint8(offset + 2) - rgb[2]).abs();
                  if (difference > 100) visible++;
                }
              }
              expect(
                visible,
                greaterThan(10),
                reason: ServiceTarget.values[index].id,
              );
            }
            final destination =
                Platform.environment['HOTARU_ICON_CONTACT_SHEET'];
            if (dark && destination != null) {
              final png = (await image.toByteData(
                format: ui.ImageByteFormat.png,
              ))!;
              await File(destination).writeAsBytes(png.buffer.asUint8List());
            }
          } finally {
            image.dispose();
          }
        });
      },
    );
  }
}
