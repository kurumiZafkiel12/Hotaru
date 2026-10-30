import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/common/network_quality.dart';
import 'package:hotaru/core/controller.dart';
import 'package:hotaru/core/interface.dart';
import 'package:hotaru/models/models.dart';
import 'package:hotaru/providers/network_quality.dart';
import 'package:hotaru/providers/providers.dart';
import 'package:hotaru/state.dart';
import 'package:hotaru/views/network_quality.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

import '../helpers/test_app.dart';

class _Core extends Mock implements CoreHandlerInterface {}

void main() {
  setUpAll(
    () => registerFallbackValue(
      const ProbeParams(url: networkQualityUrl, timeout: 3000),
    ),
  );
  for (final (size, platform) in [
    (const Size(900, 700), TargetPlatform.windows),
    (const Size(360, 740), TargetPlatform.android),
  ]) {
    for (final cancel in [false, true]) {
      testWidgets('$platform manual quality sampling, cancel=$cancel', (
        tester,
      ) async {
        final core = _Core();
        final pending = Completer<ProbeResult?>();
        var calls = 0;
        when(() => core.watchRoute(any())).thenAnswer(
          (_) async => const RouteSnapshot(coreEpoch: 7, routeVersion: 2),
        );
        when(() => core.probe(any())).thenAnswer((_) async {
          calls++;
          return cancel
              ? pending.future
              : const ProbeResult(
                  url: networkQualityUrl,
                  delay: 100,
                  statusCode: 204,
                  chains: ['node-A', 'daily'],
                );
        });
        final container = ProviderContainer(
          overrides: [
            runTimeProvider.overrideWithBuild((_, _) => 1),
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
        var disposed = false;
        Future<void> cleanup() async {
          if (!disposed) {
            await tester.pumpWidget(const SizedBox.shrink());
            container.dispose();
            disposed = true;
            await tester.pump();
          }
        }

        addTearDown(cleanup);
        globalState.container = container;
        container.read(viewSizeProvider.notifier).value = size;
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: TestApp(
              theme: ThemeData(platform: platform),
              locale: const Locale('en'),
              homeBuilder: (child) => Builder(
                builder: (context) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: const TextScaler.linear(1.5)),
                  child: child,
                ),
              ),
              child: const NetworkQualityView(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(calls, 0);
        await tester.tap(find.widgetWithText(FilledButton, 'Start'));
        await tester.pump();
        if (cancel) {
          await tester.tap(find.widgetWithText(FilledButton, 'Cancel · 0/6'));
          pending.complete(
            const ProbeResult(
              url: networkQualityUrl,
              delay: 1,
              statusCode: 204,
              chains: ['node-A'],
            ),
          );
        }
        for (var index = 0; index < 8; index++) {
          await tester.pump(const Duration(milliseconds: 200));
        }
        await tester.pumpAndSettle();
        expect(calls, cancel ? 1 : 6);
        expect(
          container.read(networkQualityProvider).report?.grade,
          cancel ? isNull : NetworkQualityGrade.excellent,
        );
        if (!cancel) {
          expect(find.text('Excellent'), findsOneWidget);
          await tester.pump(networkQualityMaxAge);
          await tester.pump();
          expect(container.read(networkQualityProvider).report, isNull);
          expect(calls, 6);
        }
        expect(tester.takeException(), isNull);
        await cleanup();
      });
    }
  }
}
