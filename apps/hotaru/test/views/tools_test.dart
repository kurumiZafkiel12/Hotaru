import 'package:hotaru/models/models.dart';
import 'package:hotaru/providers/providers.dart';
import 'package:hotaru/views/tools.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_app.dart';

final _noShortcuts = moreToolsSelectorStateProvider.overrideWith(
  (_) => const MoreToolsSelectorState(navigationItems: []),
);

void main() {
  testWidgets('the tools page lists every tool on a desktop width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      TestApp(
        wrapInProviderScope: true,
        overrides: [_noShortcuts],
        child: const ToolsView(),
      ),
    );
    await tester.pump();

    expect(find.text('Service unlock & routing check'), findsOneWidget);
    expect(find.text('Speed test'), findsWidgets);
    expect(find.text('DNS leak test'), findsOneWidget);
    expect(find.text('WebRTC / STUN leak test'), findsOneWidget);
    expect(find.text('IP profile & reputation'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the first tool starts below the title inset', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      TestApp(
        wrapInProviderScope: true,
        overrides: [_noShortcuts],
        child: const ToolsView(),
      ),
    );
    await tester.pump();

    // Without a shortcuts section, the matrix itself carries the full
    // content inset, so nothing can slide under the floating bar.
    final listView = tester.widget<ListView>(find.byType(ListView));
    final padding = listView.padding! as EdgeInsets;
    expect(padding.top, greaterThanOrEqualTo(48));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the tools page uses compact rows on a phone width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      TestApp(
        wrapInProviderScope: true,
        overrides: [_noShortcuts],
        child: const ToolsView(),
      ),
    );
    await tester.pump();

    expect(find.text('DNS leak test'), findsOneWidget);
    expect(find.text('IP profile & reputation'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
