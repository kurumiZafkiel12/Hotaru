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
}
