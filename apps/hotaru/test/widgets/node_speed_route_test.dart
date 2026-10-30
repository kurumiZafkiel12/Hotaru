import 'dart:async';

import 'package:hotaru/core/controller.dart';
import 'package:hotaru/core/interface.dart';
import 'package:hotaru/enum/enum.dart';
import 'package:hotaru/models/models.dart';
import 'package:hotaru/providers/providers.dart';
import 'package:hotaru/state.dart';
import 'package:hotaru/views/proxies/card.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

import '../helpers/test_app.dart';
import '../helpers/test_profiles.dart';

class _Core extends Mock implements CoreHandlerInterface {}

void main() {
  setUpAll(
    () => registerFallbackValue(
      const ChangeProxyParams(groupName: '', proxyName: ''),
    ),
  );

  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    for (final scenario in [
      'legacy',
      'cancel',
      'route-change',
      'route-version',
      'selected-group',
    ]) {
      testWidgets('$platform node card uses a dedicated route: $scenario', (
        tester,
      ) async {
        final core = _Core();
        final calls = <ChangeProxyParams>[];
        final pending = Completer<ChangeProxyResult>();
        when(() => core.watchRoute(any())).thenAnswer(
          (_) async => const RouteSnapshot(coreEpoch: 4, routeVersion: 0),
        );
        when(() => core.getProxies()).thenAnswer(
          (_) async => const ProxiesData(
            all: ['HOTARU-SPEEDTEST', 'HOTARU-SPEEDTEST-2'],
            proxies: {
              'node-B': {'type': 'Shadowsocks'},
              'selected-group': {'type': 'Selector', 'now': 'node-B'},
            },
          ),
        );
        when(() => core.changeProxy(any())).thenAnswer((invocation) async {
          calls.add(invocation.positionalArguments.single as ChangeProxyParams);
          return pending.future;
        });
        final container = ProviderContainer(
          overrides: [
            profilesProvider.overrideWith(TestProfiles.new),
            routeTrackerProvider.overrideWithBuild(
              (_, _) =>
                  const RouteState(proxied: true, synced: true, coreEpoch: 4),
            ),
            coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
          ],
        );
        addTearDown(container.dispose);
        globalState.container = container;
        container.read(viewSizeProvider.notifier).value = const Size(900, 600);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: TestApp(
              locale: const Locale('en'),
              theme: ThemeData(platform: platform),
              child: SizedBox(
                width: 400,
                height: 120,
                child: ProxyCard(
                  groupName: 'daily',
                  testUrl: 'https://example.com/',
                  proxy: Proxy(
                    name: scenario == 'selected-group'
                        ? 'selected-group'
                        : 'node-B',
                    type: scenario == 'selected-group'
                        ? 'Selector'
                        : 'Shadowsocks',
                  ),
                  groupType: GroupType.Selector,
                  type: ProxyCardType.standard,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final speedControl = find.byWidgetPredicate(
          (widget) => widget is Tooltip && widget.message == 'Speed test',
        );
        expect(speedControl, findsOneWidget);
        await tester.tap(speedControl);
        await tester.pump();
        if (scenario == 'cancel') {
          await tester.tap(speedControl);
        } else if (scenario == 'route-change') {
          container.read(routeTrackerProvider.notifier).bumpHostEpoch();
        } else if (scenario == 'route-version') {
          container
              .read(routeTrackerProvider.notifier)
              .applySnapshot(
                const RouteSnapshot(coreEpoch: 4, routeVersion: 1),
              );
        }
        pending.complete(
          scenario == 'legacy' || scenario == 'selected-group'
              ? const ChangeProxyResult(changed: true)
              : const ChangeProxyResult(
                  changed: true,
                  speedTestProxy: 'PROXY 127.0.0.1:1',
                  coreEpoch: 4,
                ),
        );
        await tester.pumpAndSettle();
        expect(calls, hasLength(1));
        expect(calls.single.forSpeedTest, isTrue);
        expect(calls.single.proxyName, 'node-B');
        expect(calls.single.groupName, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
