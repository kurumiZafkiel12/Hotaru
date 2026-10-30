import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/common/dns_leak.dart';
import 'package:hotaru/common/ice_probe.dart';
import 'package:hotaru/common/ip_portrait.dart';
import 'package:hotaru/core/controller.dart';
import 'package:hotaru/core/interface.dart';
import 'package:hotaru/models/models.dart';
import 'package:hotaru/providers/providers.dart';
import 'package:hotaru/state.dart';
import 'package:hotaru/views/ip_portrait.dart';
import 'package:hotaru/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

import '../helpers/test_app.dart';
import '../fixtures/ip_portrait.dart';

class _Core extends Mock implements CoreHandlerInterface {}

class _Ice extends IceProbe {
  @override
  Future<IceProbeResult> run({
    Duration timeout = const Duration(seconds: 12),
  }) async => const IceProbeResult(
    candidates: [
      IceAddress(
        address: '8.8.8.8',
        port: 3478,
        kind: 'srflx',
        protocol: 'udp',
      ),
    ],
    completed: true,
  );
  @override
  Future<void> cancel() async {}
}

void main() {
  setUpAll(() {
    registerFallbackValue(const OutboundIpParams(timeout: 8000));
    registerFallbackValue(
      const ProbeParams(url: 'https://example.com/', timeout: 8000),
    );
  });

  for (final (size, platform) in [
    (const Size(1024, 760), TargetPlatform.windows),
    (const Size(360, 740), TargetPlatform.android),
  ]) {
    for (final scenario in ['report', 'large-text', 'cancel', 'route-change']) {
      testWidgets(
        '$platform IP portrait $scenario keeps sourced conclusions honest',
        (tester) async {
          final core = _Core();
          final pending = <Completer<OutboundIpResult?>>[];
          when(() => core.watchRoute(any())).thenAnswer(
            (_) async => const RouteSnapshot(coreEpoch: 7, routeVersion: 2),
          );
          when(() => core.outboundIp(any())).thenAnswer((invocation) async {
            final params =
                invocation.positionalArguments.single as OutboundIpParams;
            if (scenario != 'report' && scenario != 'large-text') {
              final completer = Completer<OutboundIpResult?>();
              pending.add(completer);
              return completer.future;
            }
            final url = params.urls.single;
            if (url.contains('api6.ipify')) return null;
            if (Uri.parse(url).host == 'api.ipify.org') {
              return OutboundIpResult(
                url: url,
                body: '{"ip":"8.8.8.8"}',
                coreEpoch: 7,
                routeVersion: 2,
                chains: ['node-A', 'daily'],
              );
            }
            final source = IpPortraitSource.values.singleWhere(
              (source) => source.url('8.8.8.8') == url,
            );
            return OutboundIpResult(
              url: url,
              body: jsonEncode(profileJson(source)),
              coreEpoch: 7,
              routeVersion: 2,
            );
          });
          when(() => core.probe(any())).thenAnswer(
            (invocation) async => ProbeResult(
              url: (invocation.positionalArguments.single as ProbeParams).url,
              statusCode: 200,
              chains: ['node-A', 'daily'],
              rule: 'Domain',
            ),
          );
          final container = ProviderContainer(
            overrides: [
              runTimeProvider.overrideWithBuild((_, _) => 1),
              routeTrackerProvider.overrideWithBuild(
                (_, _) => const RouteState(
                  proxied: true,
                  synced: true,
                  coreEpoch: 7,
                  routeVersion: 2,
                ),
              ),
              coreHandlerProvider.overrideWithValue(
                CoreController.scoped(core),
              ),
            ],
          );
          addTearDown(container.dispose);
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          globalState.container = container;
          container.read(viewSizeProvider.notifier).value = size;
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: TestApp(
                theme: ThemeData(platform: platform),
                homeBuilder: (child) => Builder(
                  builder: (context) => MediaQuery(
                    data: MediaQuery.of(context).copyWith(
                      textScaler: TextScaler.linear(
                        scenario == 'large-text' ? 1.5 : 1,
                      ),
                    ),
                    child: child,
                  ),
                ),
                locale: const Locale('en'),
                child: IpPortraitView(
                  iceProbe: _Ice.new,
                  dnsProbe: (_) async => const [
                    DnsResolverReceipt(
                      ip: '8.8.4.4',
                      country: 'US',
                      organization: 'Google',
                    ),
                  ],
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.widgetWithText(FilledButton, 'Start'));
          await tester.pump();
          if (scenario == 'cancel') {
            await tester.tap(find.widgetWithText(FilledButton, 'Cancel'));
          } else if (scenario == 'route-change') {
            container.read(routeTrackerProvider.notifier).bumpHostEpoch();
          }
          for (final reply in pending) {
            reply.complete(null);
          }
          await tester.pumpAndSettle();
          if (scenario == 'report' || scenario == 'large-text') {
            final conclusion = find.text('Conclusion');
            final card = find
                .ancestor(of: conclusion, matching: find.byType(CommonCard))
                .first;
            expect(
              tester.getTopLeft(conclusion).dx - tester.getTopLeft(card).dx,
              closeTo(15, 2),
            );
            expect(
              find.text(
                'Providers disagree. Review the source, address and time before drawing a conclusion.',
              ),
              findsOneWidget,
            );
            await tester.scrollUntilVisible(
              find.text('IPQuery · 8.8.8.8'),
              150,
            );
            expect(find.text('IPQuery · 8.8.8.8'), findsOneWidget);
            await tester.scrollUntilVisible(find.text('DNS leak test'), 150);
            expect(find.text('No mismatch in this sample'), findsNothing);
            expect(find.text('Insufficient evidence'), findsWidgets);
          } else {
            expect(find.text('IPQuery · 8.8.8.8'), findsNothing);
            expect(find.widgetWithText(FilledButton, 'Start'), findsOneWidget);
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }
}
