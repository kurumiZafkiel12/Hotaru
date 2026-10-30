import 'dart:async';
import 'dart:convert';

import 'package:hotaru/common/node_geo.dart';
import 'package:hotaru/core/controller.dart';
import 'package:hotaru/core/interface.dart';
import 'package:hotaru/models/models.dart';
import 'package:hotaru/providers/providers.dart';
import 'package:hotaru/state.dart';
import 'package:hotaru/ui/node_globe.dart';
import 'package:hotaru/views/node_geo.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

import '../helpers/test_app.dart';

class _Core extends Mock implements CoreHandlerInterface {}

void main() {
  setUpAll(() => registerFallbackValue(const OutboundIpParams(timeout: 8000)));
  late _Core core;
  late ProviderContainer container;
  late Completer<OutboundIpResult?> pending;
  final calls = <OutboundIpParams>[];

  setUp(() {
    core = _Core();
    calls.clear();
    when(() => core.getProxies()).thenAnswer(
      (_) async => const ProxiesData(
        all: [],
        proxies: {
          'Tokyo': {'type': 'Vless'},
          'DIRECT': {'type': 'Direct'},
        },
      ),
    );
    when(() => core.outboundIp(any())).thenAnswer((invocation) {
      calls.add(invocation.positionalArguments.single as OutboundIpParams);
      pending = Completer();
      return pending.future;
    });
    container = ProviderContainer(
      overrides: [
        runTimeProvider.overrideWithBuild((_, _) => 1),
        routeTrackerProvider.overrideWithBuild(
          (_, _) => const RouteState(
            coreEpoch: 1,
            routeVersion: 1,
            live: true,
            synced: true,
            proxied: true,
          ),
        ),
        coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
      ],
    );
    globalState.container = container;
  });
  tearDown(() => container.dispose());

  Future<void> mount(
    WidgetTester tester,
    Size size,
    TargetPlatform platform,
  ) async {
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
          locale: const Locale('en'),
          child: const NodeGeoView(),
        ),
      ),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  for (final (size, platform) in [
    (const Size(1024, 760), TargetPlatform.windows),
    (const Size(360, 740), TargetPlatform.android),
  ]) {
    testWidgets(
      '$platform reads nodes, filters, and changes the map projection',
      (tester) async {
        await mount(tester, size, platform);
        expect(
          find.byWidgetPredicate(
            (widget) => widget is Text && widget.data == 'Tokyo',
          ),
          findsOneWidget,
        );
        expect(find.text('DIRECT'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('2D'));
        await tester.pump();
        expect(tester.widget<NodeGlobe>(find.byType(NodeGlobe)).flat, isTrue);
        await tester.enterText(find.byType(TextField), 'missing');
        await tester.pump();
        expect(
          find.byWidgetPredicate(
            (widget) => widget is Text && widget.data == 'Tokyo',
          ),
          findsNothing,
        );
        await tester.enterText(find.byType(TextField), 'Tokyo');
        await tester.pump();
        expect(
          find.byWidgetPredicate(
            (widget) => widget is Text && widget.data == 'Tokyo',
          ),
          findsOneWidget,
        );
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('cancelled node replies cannot populate the map', (tester) async {
    await mount(tester, const Size(1024, 760), TargetPlatform.windows);
    await tester.tap(find.text('Test all nodes'));
    await tester.pump();
    expect(calls.single.proxyName, 'Tokyo');
    expect(calls.single.urls, [nodeGeoSource]);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    pending.complete(
      OutboundIpResult(
        url: nodeGeoSource,
        body: jsonEncode({
          'ip': '8.8.8.8',
          'latitude': 35,
          'longitude': 139,
          'country_code': 'JP',
        }),
        chains: const ['Tokyo'],
      ),
    );
    await tester.pump();
    expect(tester.widget<NodeGlobe>(find.byType(NodeGlobe)).markers, isEmpty);
    expect(find.textContaining('8.8.8.8'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'a verified exit focuses the globe and becomes stale after route change',
    (tester) async {
      await mount(tester, const Size(1024, 760), TargetPlatform.windows);
      await tester.tap(find.text('Test all nodes'));
      await tester.pump();
      pending.complete(
        OutboundIpResult(
          url: nodeGeoSource,
          coreEpoch: 1,
          routeVersion: 1,
          body: jsonEncode({
            'ip': '8.8.8.8',
            'latitude': 35,
            'longitude': 139,
            'country_code': 'JP',
          }),
          chains: const ['Tokyo'],
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        tester.widget<NodeGlobe>(find.byType(NodeGlobe)).markers.single.id,
        'Tokyo',
      );
      await tester.tap(
        find.byWidgetPredicate(
          (widget) => widget is Text && widget.data == 'Tokyo',
        ),
      );
      await tester.pump();
      expect(
        tester.widget<NodeGlobe>(find.byType(NodeGlobe)).focus?.latitude,
        35,
      );
      container
          .read(routeTrackerProvider.notifier)
          .applySnapshot(const RouteSnapshot(coreEpoch: 1, routeVersion: 2));
      await tester.pump();
      expect(tester.widget<NodeGlobe>(find.byType(NodeGlobe)).markers, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
    },
  );

  testWidgets('node loading failure keeps the map and retry available', (
    tester,
  ) async {
    when(() => core.getProxies()).thenThrow(StateError('offline'));
    await mount(tester, const Size(360, 740), TargetPlatform.android);
    expect(find.byType(NodeGlobe), findsOneWidget);
    expect(find.text('Probe failed; see evidence'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
