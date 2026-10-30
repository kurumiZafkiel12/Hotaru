import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/common/network_quality.dart';
import 'package:hotaru/core/controller.dart';
import 'package:hotaru/core/interface.dart';
import 'package:hotaru/models/models.dart';
import 'package:hotaru/providers/network_quality.dart';
import 'package:hotaru/providers/providers.dart';
import 'package:mocktail/mocktail.dart';

class _Core extends Mock implements CoreHandlerInterface {}

void main() {
  test(
    'cached grades require a live matching route and a recent timestamp',
    () {
      const route = RouteState(
        coreEpoch: 7,
        routeVersion: 2,
        hostEpoch: 3,
        proxied: true,
        synced: true,
        live: true,
      );
      final report = NetworkQualityReport(
        samples: const [],
        checkedAt: DateTime.now(),
      );
      final state = NetworkQualityState(report: report, route: route);
      expect(state.reportFor(route), same(report));
      for (final changed in [
        route.copyWith(live: false),
        route.copyWith(synced: false),
        route.copyWith(coreEpoch: 8),
        route.copyWith(routeVersion: 3),
        route.copyWith(hostEpoch: 4),
        route.copyWith(proxied: false),
      ]) {
        expect(state.reportFor(changed), isNull);
      }
      final old = NetworkQualityState(
        report: NetworkQualityReport(
          samples: const [],
          checkedAt: DateTime.now().subtract(const Duration(minutes: 6)),
        ),
        route: route,
      );
      expect(old.reportFor(route), isNull);
    },
  );
  setUpAll(
    () => registerFallbackValue(
      const ProbeParams(url: networkQualityUrl, timeout: 3000),
    ),
  );

  test(
    'idle provider does no network work, successful report is invalidated by network change',
    () async {
      final core = _Core();
      var calls = 0;
      when(() => core.watchRoute(any())).thenAnswer(
        (_) async => const RouteSnapshot(coreEpoch: 7, routeVersion: 2),
      );
      when(() => core.probe(any())).thenAnswer((_) async {
        calls++;
        return const ProbeResult(
          url: networkQualityUrl,
          delay: 100,
          statusCode: 204,
          chains: ['node-A'],
        );
      });
      final container = ProviderContainer(
        overrides: [
          routeTrackerProvider.overrideWithBuild(
            (_, _) => const RouteState(
              proxied: true,
              live: true,
              synced: true,
              coreEpoch: 7,
              routeVersion: 2,
            ),
          ),
          coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
        ],
      );
      addTearDown(container.dispose);
      expect(container.read(networkQualityProvider).report, isNull);
      expect(calls, 0);
      await container.read(networkQualityProvider.notifier).measure();
      expect(calls, 6);
      expect(
        container.read(networkQualityProvider).report?.grade,
        NetworkQualityGrade.excellent,
      );
      container.read(routeTrackerProvider.notifier).bumpHostEpoch();
      await Future<void>.delayed(Duration.zero);
      expect(container.read(networkQualityProvider).report, isNull);
      expect(calls, 6);
    },
  );

  test(
    'core epoch change cancels a pending measurement without accepting its late reply',
    () async {
      final pending = Completer<ProbeResult?>();
      final core = _Core();
      when(() => core.watchRoute(any())).thenAnswer(
        (_) async => const RouteSnapshot(coreEpoch: 7, routeVersion: 2),
      );
      when(() => core.probe(any())).thenAnswer((_) => pending.future);
      final container = ProviderContainer(
        overrides: [
          routeTrackerProvider.overrideWithBuild(
            (_, _) => const RouteState(
              proxied: true,
              live: true,
              synced: true,
              coreEpoch: 7,
              routeVersion: 2,
            ),
          ),
          coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
        ],
      );
      addTearDown(container.dispose);
      final running = container.read(networkQualityProvider.notifier).measure();
      container
          .read(routeTrackerProvider.notifier)
          .applySnapshot(const RouteSnapshot(coreEpoch: 8, routeVersion: 3));
      pending.complete(
        const ProbeResult(
          url: networkQualityUrl,
          delay: 10,
          statusCode: 204,
          chains: ['node-A'],
        ),
      );
      await running;
      await Future<void>.delayed(Duration.zero);
      expect(container.read(networkQualityProvider).report, isNull);
      expect(container.read(networkQualityProvider).running, isFalse);
      verify(() => core.probe(any())).called(1);
    },
  );
}
