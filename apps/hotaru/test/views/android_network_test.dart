import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/common/android_network.dart';
import 'package:hotaru/providers/android_network.dart';
import 'package:hotaru/providers/providers.dart';
import 'package:hotaru/state.dart';
import 'package:hotaru/views/android_network.dart';
import 'package:hotaru/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_app.dart';

const _snapshot = AndroidNetworkSnapshot(
  readable: true,
  api: 35,
  active: true,
  vpn: true,
  validated: true,
  captivePortal: false,
  metered: false,
  privateDnsActive: false,
  transports: ['vpn', 'wifi'],
  dnsServers: ['10.0.2.3', '2606:4700:4700::1111'],
);

void main() {
  for (final scenario in ['observed', 'old-api', 'unavailable', 'resume']) {
    testWidgets(
      'Android maintenance $scenario keeps system state distinct from Hotaru',
      (tester) async {
        var reads = 0;
        final pending = Completer<AndroidNetworkSnapshot>();
        final settings = <AndroidNetworkSetting>[];
        final container = ProviderContainer(
          overrides: [
            runTimeProvider.overrideWithBuild((_, _) => null),
            androidNetworkSnapshotProvider.overrideWith((_) async {
              reads++;
              if (scenario == 'resume' && reads == 2) return pending.future;
              return switch (scenario) {
                'unavailable' => const AndroidNetworkSnapshot(readable: false),
                'old-api' => const AndroidNetworkSnapshot(
                  readable: true,
                  api: 24,
                ),
                _ => _snapshot,
              };
            }),
            androidNetworkSettingsProvider.overrideWithValue((setting) async {
              settings.add(setting);
              return setting != AndroidNetworkSetting.wifi;
            }),
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
        const size = Size(360, 740);
        container.read(viewSizeProvider.notifier).value = size;
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: TestApp(
              theme: ThemeData(platform: TargetPlatform.android),
              locale: const Locale('en'),
              homeBuilder: (child) => Builder(
                builder: (context) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: const TextScaler.linear(1.5)),
                  child: child,
                ),
              ),
              child: const AndroidNetworkView(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(reads, 1);
        Finder row(String label) => find
            .ancestor(of: find.text(label), matching: find.byType(Row))
            .first;
        if (scenario == 'observed' || scenario == 'resume') {
          await tester.scrollUntilVisible(
            find.text('System VPN on default network'),
            120,
          );
          expect(
            find.descendant(
              of: row('Hotaru'),
              matching: find.text('Not running'),
            ),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: row('System VPN on default network'),
              matching: find.text('Yes'),
            ),
            findsOneWidget,
          );
        }
        if (scenario == 'resume') {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.paused,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          await tester.pump();
          expect(reads, 2);
          expect(
            find.descendant(
              of: row('System VPN on default network'),
              matching: find.text('Unknown'),
            ),
            findsOneWidget,
          );
          pending.complete(
            const AndroidNetworkSnapshot(readable: true, api: 35, vpn: false),
          );
          await tester.pumpAndSettle();
          expect(
            find.descendant(
              of: row('System VPN on default network'),
              matching: find.text('No'),
            ),
            findsOneWidget,
          );
        } else if (scenario == 'observed') {
          await tester.scrollUntilVisible(
            find.widgetWithText(TonalButton, 'VPN'),
            150,
          );
          await tester.tap(find.widgetWithText(TonalButton, 'VPN'));
          await tester.pumpAndSettle();
          expect(settings, [AndroidNetworkSetting.vpn]);
          final wifi = find.widgetWithText(TonalButton, 'Wi-Fi settings');
          await tester.ensureVisible(wifi);
          await tester.tap(wifi);
          await tester.pumpAndSettle();
          expect(
            find.text('This settings page is unavailable on this device.'),
            findsOneWidget,
          );
        } else if (scenario == 'old-api') {
          await tester.scrollUntilVisible(
            find.widgetWithText(TonalButton, 'System Private DNS'),
            150,
          );
          final button = tester.widget<TonalButton>(
            find.widgetWithText(TonalButton, 'System Private DNS'),
          );
          expect(button.onPressed, isNull);
          expect(settings, isEmpty);
        } else {
          expect(
            find.text(
              'Network status could not be read or is restricted by the system. Refresh or inspect the system settings.',
            ),
            findsOneWidget,
          );
          await tester.scrollUntilVisible(
            find.text('System VPN on default network'),
            120,
          );
          expect(
            find.descendant(
              of: row('System VPN on default network'),
              matching: find.text('Unknown'),
            ),
            findsOneWidget,
          );
        }
        expect(tester.takeException(), isNull);
        await cleanup();
      },
    );
  }
}
