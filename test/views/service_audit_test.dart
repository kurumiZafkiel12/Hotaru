import 'dart:async';

import 'package:hotaru/common/service_probe.dart';
import 'package:hotaru/core/controller.dart';
import 'package:hotaru/core/interface.dart';
import 'package:hotaru/models/models.dart';
import 'package:hotaru/providers/providers.dart';
import 'package:hotaru/state.dart';
import 'package:hotaru/views/service_audit.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

import '../helpers/test_app.dart';

class _MockCore extends Mock implements CoreHandlerInterface {}

void main() {
  setUpAll(() {
    registerFallbackValue(const ServiceCheckParams(timeout: 0));
    registerFallbackValue(const CheckRoutesParams());
  });
  late _MockCore core;
  late ProviderContainer container;
  final calls = <ServiceCheckParams>[];
  Future<List<ServiceCheckItem>> Function(ServiceCheckParams)? answer;

  setUp(() {
    core = _MockCore();
    calls.clear();
    answer = null;
    when(() => core.serviceCheck(any())).thenAnswer((invocation) async {
      final params =
          invocation.positionalArguments.single as ServiceCheckParams;
      calls.add(params);
      if (params.cancel) return [];
      if (answer != null) return answer!(params);
      return [
        ServiceCheckItem(
          name: params.names.single,
          status: 'reachable',
          region: 'JP',
          delay: 42,
          coreEpoch: 1,
          routeVersion: 1,
          hits: const [RouteHit(host: 'controlled.test:443', exit: 'ExitB')],
          observations: const [
            ServiceObservation(
              url: 'https://controlled.test/',
              statusCode: 204,
              rule: 'DomainKeyword',
              rulePayload: 'controlled',
              chains: ['ExitB', 'AI Group'],
            ),
          ],
        ),
      ];
    });
    when(() => core.checkRoutes(any())).thenAnswer(
      (_) async =>
          const RouteCheck(coreEpoch: 1, routeVersion: 1, held: [true]),
    );
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
    tester.view.physicalSize = const Size(1000, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    container.read(viewSizeProvider.notifier).value = const Size(1000, 1200);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const TestApp(child: ServiceAuditView()),
      ),
    );
    await tester.pump();
  }

  Future<void> frames(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }

  test('catalog covers the requested categories without duplicates', () {
    expect(ServiceTarget.values, hasLength(57));
    final counts = <String, int>{};
    for (final target in ServiceTarget.values) {
      counts.update(target.category, (count) => count + 1, ifAbsent: () => 1);
    }
    expect(counts, {
      'ai': 13,
      'media': 17,
      'domestic': 6,
      'social': 9,
      'developer': 7,
      'games': 5,
    });
  });

  testWidgets(
    'does not probe before start; AI filter checks exactly its thirteen services',
    (tester) async {
      await pump(tester);
      expect(calls, isEmpty);
      await tester.tap(find.widgetWithText(ChoiceChip, 'AI & models'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Start'));
      await frames(tester);
      final checked = calls
          .where((call) => !call.cancel)
          .expand((call) => call.names)
          .toSet();
      expect(
        checked,
        ServiceTarget.values
            .where((target) => target.category == 'ai')
            .map((target) => target.id)
            .toSet(),
      );
      expect(checked, hasLength(13));
      expect(calls.every((call) => call.runId.isNotEmpty), isTrue);
      expect(
        find.textContaining('Reachable · unlock unconfirmed'),
        findsWidgets,
      );
      expect(tester.takeException(), isNull);
      await close(tester);
    },
  );

  testWidgets(
    'single retry preserves observed HTTP, rule, group and exit evidence',
    (tester) async {
      await pump(tester);
      await tester.tap(find.byTooltip('Retry').first);
      await frames(tester);
      expect(calls.where((call) => !call.cancel).single.names, ['google']);
      await tester.tap(find.text('Google Workspace').first);
      await frames(tester);
      expect(find.text('HTTP 204'), findsOneWidget);
      expect(
        find.textContaining('DomainKeyword, controlled ➜ AI Group ➜ ExitB'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await close(tester);
    },
  );

  testWidgets(
    'cancel sends the run token, stops queueing and rejects late results',
    (tester) async {
      final pending = Completer<List<ServiceCheckItem>>();
      answer = (_) => pending.future;
      await pump(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Start'));
      await tester.pump();
      expect(calls.where((call) => !call.cancel), hasLength(4));
      final id = calls.first.runId;
      await tester.tap(find.widgetWithText(FilledButton, 'Cancel'));
      await tester.pump();
      expect(calls.any((call) => call.cancel && call.runId == id), isTrue);
      pending.complete([
        const ServiceCheckItem(
          name: 'google',
          status: 'available',
          region: 'US',
        ),
      ]);
      await frames(tester);
      expect(calls.where((call) => !call.cancel), hasLength(4));
      expect(find.text('0 / 57'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await close(tester);
    },
  );

  testWidgets('transport errors release the start button and show a failure', (
    tester,
  ) async {
    answer = (_) async => throw StateError('controlled failure');
    await pump(tester);
    await tester.tap(find.byTooltip('Retry').first);
    await frames(tester);
    expect(find.textContaining('controlled failure'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Start'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await close(tester);
  });
}
