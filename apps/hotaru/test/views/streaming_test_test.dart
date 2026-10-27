import 'package:hotaru/common/service_probe.dart';
import 'package:hotaru/core/controller.dart';
import 'package:hotaru/core/interface.dart';
import 'package:hotaru/models/models.dart';
import 'package:hotaru/providers/providers.dart';
import 'package:hotaru/state.dart';
import 'package:hotaru/views/streaming_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

import '../helpers/test_app.dart';

class _MockCore extends Mock implements CoreHandlerInterface {}

void main() {
  setUpAll(() {
    registerFallbackValue(const ServiceCheckParams(timeout: 0));
  });
  late _MockCore core;
  late ProviderContainer container;
  final statuses = <String, String>{};

  setUp(() {
    core = _MockCore();
    statuses.clear();
    when(() => core.serviceCheck(any())).thenAnswer((invocation) async {
      final params =
          invocation.positionalArguments.single as ServiceCheckParams;
      if (params.cancel) return [];
      return [
        for (final name in params.names)
          ServiceCheckItem(
            name: name,
            status: statuses[name] ?? 'reachable',
            region: 'JP',
            delay: 42,
            coreEpoch: 1,
            routeVersion: 1,
          ),
      ];
    });
    container = ProviderContainer(
      overrides: [
        runTimeProvider.overrideWithBuild((_, _) => 1),
        routeTrackerProvider.overrideWithBuild(
          (_, _) => const RouteState(
            coreEpoch: 1,
            routeVersion: 1,
            synced: true,
            live: true,
            proxied: true,
          ),
        ),
        coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
      ],
    );
    globalState.container = container;
  });

  tearDown(() => container.dispose());

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    container.read(viewSizeProvider.notifier).value = const Size(1000, 1400);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const TestApp(child: StreamingTestView()),
      ),
    );
    await tester.pump();
  }

  Future<void> runAll(WidgetTester tester) async {
    await tester.tap(find.text('Start'));
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }
  }

  testWidgets('the catalog renders idle with summary counters at zero', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('Streaming unlock test'), findsOneWidget);
    expect(find.text('Netflix'), findsOneWidget);
    expect(find.text('0 / ${ServiceTarget.values.length}'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('U-NEXT'), 200);
    expect(find.text('U-NEXT'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('verdicts land in their buckets with the region and latency', (
    tester,
  ) async {
    statuses['netflix'] = 'available';
    statuses['disney-plus'] = 'unsupported-region';
    statuses['chatgpt'] = 'challenge';
    await pump(tester);
    await runAll(tester);

    expect(find.text('Unlocked · 1'), findsOneWidget);
    expect(find.text('Not unlocked · 1'), findsOneWidget);
    // Netflix's row shows its small secondary line: flag region + ms.
    expect(find.text('JP · 42 ms'), findsWidgets);
    expect(find.text('Region not supported'), findsOneWidget);
    expect(
      find.text(
        '${ServiceTarget.values.length} / ${ServiceTarget.values.length}',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('the locked-only filter keeps just the not-unlocked rows', (
    tester,
  ) async {
    statuses['netflix'] = 'available';
    statuses['disney-plus'] = 'unsupported-region';
    await pump(tester);
    await runAll(tester);
    await tester.tap(find.text('Locked only'));
    await tester.pump();

    expect(find.text('Disney+'), findsOneWidget);
    expect(find.text('Netflix'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
