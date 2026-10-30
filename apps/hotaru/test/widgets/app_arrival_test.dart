import 'package:hotaru/ui/app_arrival.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  Widget scene({bool reducedMotion = false}) => MediaQuery(
    data: MediaQueryData(disableAnimations: reducedMotion),
    child: const Directionality(
      textDirection: TextDirection.ltr,
      child: AppArrival(child: SizedBox(width: 400, height: 800)),
    ),
  );

  testWidgets('first frame fades and lifts two logical pixels within 250ms', (
    tester,
  ) async {
    await tester.pumpWidget(scene());
    final opacity = find.descendant(
      of: find.byType(AppArrival),
      matching: find.byType(Opacity),
    );
    expect(tester.widget<Opacity>(opacity).opacity, 0);
    final transform = find.descendant(
      of: find.byType(AppArrival),
      matching: find.byType(Transform),
    );
    expect(tester.widget<Transform>(transform).transform.getTranslation().y, 2);
    await tester.pump(const Duration(milliseconds: 125));
    expect(tester.widget<Opacity>(opacity).opacity, inExclusiveRange(0, 1));
    await tester.pump(const Duration(milliseconds: 125));
    expect(tester.widget<Opacity>(opacity).opacity, 1);
    expect(tester.widget<Transform>(transform).transform.getTranslation().y, 0);
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('reduced motion displays the ready page immediately', (
    tester,
  ) async {
    await tester.pumpWidget(scene(reducedMotion: true));
    final opacity = find.descendant(
      of: find.byType(AppArrival),
      matching: find.byType(Opacity),
    );
    expect(tester.widget<Opacity>(opacity).opacity, 1);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(const SizedBox());
  });
  Widget branded({required VoidCallback onTap, bool reducedMotion = false}) =>
      MediaQuery(
        data: MediaQueryData(disableAnimations: reducedMotion),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: AppArrival(
            brandMark: const ColoredBox(
              key: ValueKey('brand'),
              color: Colors.green,
            ),
            brandLabel: 'Hotaru',
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onTap,
              child: const SizedBox(
                key: ValueKey('page'),
                width: 400,
                height: 800,
              ),
            ),
          ),
        ),
      );

  testWidgets(
    'the Android brand sequence cross-fades into the interactive page',
    (tester) async {
      var taps = 0;
      await tester.pumpWidget(branded(onTap: () => taps++));
      final page = find.byKey(const ValueKey('page'));
      final pageOpacity = find.ancestor(
        of: page,
        matching: find.byType(Opacity),
      );
      expect(tester.widget<Opacity>(pageOpacity).opacity, 0);
      expect(find.byKey(const ValueKey('brand')), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.widget<Opacity>(pageOpacity).opacity, 0);
      await tester.tap(page, warnIfMissed: false);
      expect(taps, 0);
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        tester.widget<Opacity>(pageOpacity).opacity,
        inExclusiveRange(0, 1),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.widget<Opacity>(pageOpacity).opacity, 1);
      expect(find.byKey(const ValueKey('brand')), findsNothing);
      await tester.tap(find.byType(GestureDetector));
      expect(taps, 1);
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'reduced motion skips the brand sequence and an interrupted intro disposes',
    (tester) async {
      await tester.pumpWidget(branded(onTap: () {}, reducedMotion: true));
      expect(find.byKey(const ValueKey('brand')), findsNothing);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(branded(onTap: () {}));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpWidget(const SizedBox());
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
