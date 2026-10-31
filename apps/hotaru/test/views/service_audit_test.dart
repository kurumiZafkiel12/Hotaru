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

  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(1000, 1200),
    TargetPlatform platform = TargetPlatform.windows,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    container.read(viewSizeProvider.notifier).value = size;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TestApp(
          theme: ThemeData(platform: platform),
          child: const ServiceAuditView(),
        ),
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

  for (final resumeOnly in [true, false]) {
    testWidgets(
      resumeOnly
          ? 'returning to the foreground preserves measured routes'
          : 'a real host route change invalidates measured routes',
      (tester) async {
        await pump(tester);
        await tester.tap(find.widgetWithText(ChoiceChip, 'AI & models'));
        await tester.pump();
        await tester.tap(find.widgetWithText(FilledButton, 'Start'));
        await frames(tester);
        final tracker = container.read(routeTrackerProvider.notifier);
        if (resumeOnly) {
          tracker.markResumed();
        } else {
          tracker.bumpHostEpoch();
        }
        await frames(tester);
        final stale = find.text('Route changed · run again');
        expect(stale, resumeOnly ? findsNothing : findsWidgets);
        await close(tester);
      },
    );
  }

  test('catalog covers the requested categories without duplicates', () {
    expect(ServiceTarget.values, hasLength(63));
    final counts = <String, int>{};
    for (final target in ServiceTarget.values) {
      counts.update(target.category, (count) => count + 1, ifAbsent: () => 1);
    }
    expect(counts, {
      'ai': 13,
      'media': 23,
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
      expect(find.text('Unlocked 13'), findsOneWidget);
      expect(find.text('13 / 13'), findsOneWidget);
      expect(find.text('Available'), findsNothing);
      expect(calls.every((call) => call.runId.isNotEmpty), isTrue);
      expect(find.textContaining('Unlocked', findRichText: true), findsWidgets);
      expect(tester.takeException(), isNull);
      await close(tester);
    },
  );

  testWidgets(
    'unrelated group version changes preserve results whose actual exits still match',
    (tester) async {
      await pump(tester);
      await tester.tap(find.widgetWithText(ChoiceChip, 'AI & models'));
      await tester.tap(find.widgetWithText(FilledButton, 'Start'));
      await frames(tester);
      expect(find.text('Unlocked 13'), findsOneWidget);
      when(() => core.checkRoutes(any())).thenAnswer((invocation) async {
        final routes =
            (invocation.positionalArguments.single as CheckRoutesParams).routes;
        return RouteCheck(
          coreEpoch: 1,
          routeVersion: 2,
          held: [for (final _ in routes) true],
        );
      });
      container
          .read(routeTrackerProvider.notifier)
          .applySnapshot(const RouteSnapshot(coreEpoch: 1, routeVersion: 2));
      await frames(tester);
      expect(find.text('Unlocked 13'), findsOneWidget);
      expect(find.text('Route changed · run again'), findsNothing);
      await close(tester);
    },
  );

  for (final failedVerification in [false, true]) {
    testWidgets(
      'route revalidation distinguishes changed exits from unavailable evidence: $failedVerification',
      (tester) async {
        await pump(tester);
        await tester.tap(find.widgetWithText(ChoiceChip, 'AI & models'));
        await tester.tap(find.widgetWithText(FilledButton, 'Start'));
        await frames(tester);
        when(() => core.checkRoutes(any())).thenAnswer((invocation) async {
          if (failedVerification) return null;
          final routes =
              (invocation.positionalArguments.single as CheckRoutesParams)
                  .routes;
          return RouteCheck(
            coreEpoch: 1,
            routeVersion: 2,
            held: [for (var i = 0; i < routes.length; i++) i != 0],
          );
        });
        container
            .read(routeTrackerProvider.notifier)
            .applySnapshot(const RouteSnapshot(coreEpoch: 1, routeVersion: 2));
        await frames(tester);
        expect(
          find.text(
            failedVerification ? 'Unable to determine 13' : 'Unlocked 12',
          ),
          findsOneWidget,
        );
        expect(
          find.text('Route changed · run again'),
          failedVerification ? findsNothing : findsOneWidget,
        );
        await close(tester);
      },
    );
  }

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
      expect(find.text('0 / 63'), findsOneWidget);
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
  testWidgets(
    'result filters classify passed endpoints while preserving actual restrictions',
    (tester) async {
      const states = {
        'google': 'available',
        'netflix': 'originals-only',
        'youtube': 'unsupported-region',
        'chatgpt': 'blocked',
        'claude': 'challenge',
        'gemini': 'timeout',
        'docker': 'inconclusive',
      };
      answer = (params) async => [
        ServiceCheckItem(
          name: params.names.single,
          status: states[params.names.single] ?? 'reachable',
          delay: 42,
        ),
      ];
      await pump(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Start'));
      await frames(tester);
      for (final text in [
        'Unlocked 57',
        'Partially unlocked 1',
        'Not unlocked 1',
        'Unsupported region 1',
        'Verification / login required 1',
        'Failed / timed out 1',
        'Unable to determine 1',
      ]) {
        expect(find.text(text), findsOneWidget);
      }
      await tester.tap(find.text('Not unlocked 1'));
      await frames(tester);
      expect(find.text('ChatGPT'), findsOneWidget);
      expect(find.text('Google Workspace'), findsNothing);
      expect(find.text('63 / 63'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await close(tester);
    },
  );
  testWidgets(
    'phone filters stay compact and horizontal swipes preserve the result list',
    (tester) async {
      await pump(
        tester,
        size: const Size(390, 844),
        platform: TargetPlatform.android,
      );
      final start = find.widgetWithText(FilledButton, 'Start');
      expect(
        tester.getBottomRight(find.text('Google Workspace')).dy,
        lessThan(844),
      );
      await tester.tap(start);
      await frames(tester);
      expect(find.text('63 / 63'), findsOneWidget);
      final strip = find
          .byWidgetPredicate(
            (widget) =>
                widget is SingleChildScrollView &&
                widget.scrollDirection == Axis.horizontal,
          )
          .first;
      final position = tester
          .state<ScrollableState>(
            find.descendant(of: strip, matching: find.byType(Scrollable)).first,
          )
          .position;
      final before = position.pixels;
      await tester.drag(strip, const Offset(-650, 0));
      await frames(tester);
      expect(position.pixels, greaterThan(before));
      final unknown = find.widgetWithText(ChoiceChip, 'Unable to determine 0');
      position.jumpTo(position.maxScrollExtent);
      await frames(tester);
      final center = tester.getCenter(unknown);
      expect(center.dx, inExclusiveRange(0, 390));
      expect(center.dy, greaterThan(56));
      await tester.tap(unknown);
      await frames(tester);
      expect(tester.widget<ChoiceChip>(unknown).selected, isTrue);
      expect(find.text('Google Workspace'), findsNothing);
      expect(tester.takeException(), isNull);
      await close(tester);
    },
  );
}
