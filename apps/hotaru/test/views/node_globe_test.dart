import 'package:hotaru/models/models.dart';
import 'package:hotaru/providers/providers.dart';
import 'package:hotaru/views/node_globe.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_app.dart';

void main() {
  testWidgets('the globe renders its dotted earth and idle state', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
      TestApp(
        wrapInProviderScope: true,
        overrides: [
          groupsProvider.overrideWithValue(const <Group>[]),
          routeTrackerProvider.overrideWithBuild(
            (_, _) => const RouteState(
              coreEpoch: 1,
              routeVersion: 1,
              synced: true,
              live: true,
              proxied: true,
            ),
          ),
        ],
        child: const NodeGlobeView(),
      ),
    );
    await tester.pump();
    expect(find.text('Node exits not checked yet'), findsOneWidget);
    expect(find.byType(CustomPaint), findsWidgets);
    await tester.pumpWidget(const SizedBox());
  });
}
