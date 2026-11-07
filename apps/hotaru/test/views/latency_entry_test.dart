import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/controller.dart';
import 'package:hotaru/core/interface.dart';
import 'package:hotaru/enum/enum.dart';
import 'package:hotaru/l10n/l10n.dart';
import 'package:hotaru/models/models.dart';
import 'package:hotaru/providers/providers.dart';
import 'package:hotaru/views/network_quality.dart';
import 'package:hotaru/views/speed_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

import '../helpers/test_app.dart';

class _Core extends Mock implements CoreHandlerInterface {}

void main() {
  setUpAll(
    () => registerFallbackValue(
      const ProbeParams(url: 'https://example.org', timeout: 3000),
    ),
  );
  for (final locale in const [
    Locale('en'),
    Locale('zh', 'CN'),
    Locale('ja'),
    Locale('ru'),
    Locale('fr'),
    Locale('es'),
    Locale('ko'),
  ]) {
    testWidgets(
      'Windows latency rating remains reachable and manual in $locale',
      (tester) async {
        tester.view.physicalSize = const Size(1000, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final core = _Core();
        when(() => core.watchRoute(any())).thenAnswer(
          (_) async => const RouteSnapshot(coreEpoch: 7, routeVersion: 2),
        );
        await tester.pumpWidget(
          TestApp(
            locale: locale,
            overrides: [
              runTimeProvider.overrideWithBuild((_, _) => 1),
              routeTrackerProvider.overrideWithBuild(
                (_, _) => const RouteState(
                  coreEpoch: 7,
                  routeVersion: 2,
                  proxied: true,
                  synced: true,
                  live: true,
                ),
              ),
              coreHandlerProvider.overrideWithValue(
                CoreController.scoped(core),
              ),
            ],
            child: const SpeedTestView(platform: SupportPlatform.Windows),
          ),
        );
        await tester.pumpAndSettle();
        final context = tester.element(find.byType(SpeedTestView));
        final label = AppLocalizations.of(context).networkLatencyRating;
        expect(find.byTooltip(label), findsOneWidget);
        await tester.tap(find.byTooltip(label));
        await tester.pumpAndSettle();
        expect(find.byType(NetworkQualityView), findsOneWidget);
        expect(find.text(label), findsOneWidget);
        verifyNever(() => core.probe(any()));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      },
    );
  }

  testWidgets('Android layout is left for the separate platform port', (
    tester,
  ) async {
    await tester.pumpWidget(
      const TestApp(
        locale: Locale('en'),
        wrapInProviderScope: true,
        child: SpeedTestView(platform: SupportPlatform.Android),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('Latency rating'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
