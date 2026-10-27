import 'package:hotaru/views/speed_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_app.dart';

void main() {
  testWidgets('the speed page composes gauge, phases, stats and info', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const TestApp(wrapInProviderScope: true, child: SpeedTestView()),
    );
    await tester.pump();

    // The needle dial is on the page with its zeroed readout.
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is CustomPaint &&
            widget.painter.runtimeType.toString() == '_NeedlePainter',
      ),
      findsOneWidget,
    );
    expect(find.text('0.0'), findsOneWidget);
    // Phase dots lead with latency.
    expect(find.text('Delay'), findsNWidgets(2));
    // The four stat tiles are all on the composed screen.
    expect(find.text('Download'), findsWidgets);
    expect(find.text('Upload'), findsWidgets);
    expect(find.text('Jitter'), findsOneWidget);
    // Info rows: with no profile the exit node stays honestly unknown.
    expect(find.text('Exit node'), findsOneWidget);
    expect(find.text('Unknown'), findsWidgets);
    expect(find.text('Route rule'), findsOneWidget);
    expect(find.text('Server'), findsOneWidget);
    // The live trace panel exists before any run, in its empty state.
    expect(find.text('Live rate'), findsOneWidget);
    expect(find.text('No test run yet'), findsOneWidget);
    // One big start button.
    expect(find.text('Start'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the speed page stacks on a phone width', (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const TestApp(wrapInProviderScope: true, child: SpeedTestView()),
    );
    await tester.pump();

    expect(find.text('0.0'), findsOneWidget);
    expect(find.text('Start'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
