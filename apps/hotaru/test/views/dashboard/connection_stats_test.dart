import 'package:hotaru/core/controller.dart';
import 'package:hotaru/core/interface.dart';
import 'package:hotaru/enum/enum.dart';
import 'package:hotaru/features/connection/tracker_info_list.dart';
import 'package:hotaru/models/models.dart';
import 'package:hotaru/providers/providers.dart';
import 'package:hotaru/state.dart';
import 'package:hotaru/views/connection/connections.dart';
import 'package:hotaru/views/connection/requests.dart';
import 'package:hotaru/views/dashboard/widgets/connection_stats.dart';
import 'package:hotaru/views/dashboard/layout.dart';
import 'package:hotaru/views/dns_queries.dart';
import 'package:hotaru/widgets/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

import '../../helpers/test_app.dart';
import '../../helpers/test_profiles.dart';

class _MockCore extends Mock implements CoreHandlerInterface {}

const _mobileSize = Size(400, 800);

TrackerInfo _request(int index) {
  return TrackerInfo(
    id: '$index',
    start: DateTime.utc(2026),
    metadata: Metadata(
      network: 'tcp',
      host: 'host-$index.test',
      destinationIP: '1.1.1.1',
      destinationPort: '443',
      process: 'curl',
    ),
    chains: const ['Proxy'],
    rule: 'DOMAIN',
    rulePayload: 'host-$index.test',
  );
}

Finder _stat(String label) => find.descendant(
  of: find.byType(ConnectionStatsCard),
  matching: find.text(label),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MockCore core;
  late ProviderContainer container;

  setUp(() {
    core = _MockCore();
    when(() => core.getConnectionCount()).thenAnswer((_) async => 0);
    when(() => core.getConnections()).thenAnswer((_) async => const []);
    container = ProviderContainer(
      overrides: [
        profilesProvider.overrideWith(TestProfiles.new),
        coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
        coreStatusProvider.overrideWithBuild((_, _) => CoreStatus.connected),
      ],
    );
    globalState.container = container;
  });

  tearDown(() => container.dispose());

  Future<void> pumpCard(
    WidgetTester tester, {
    Size size = _mobileSize,
    Locale? locale,
    DashboardDensity density = DashboardDensity.mobile,
    double textScale = 1,
  }) async {
    container.read(viewSizeProvider.notifier).value = size;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TestApp(
          locale: locale,
          theme: ThemeData(
            platform: density.isDesktop
                ? TargetPlatform.windows
                : TargetPlatform.android,
          ).withAppTypography,
          homeBuilder: (child) => Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: child,
            ),
          ),
          child: Scaffold(
            body: density.isDesktop
                ? Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: 200,
                      height: 122,
                      child: DashboardDensityScope(
                        density: density,
                        scale: textScale,
                        child: const ConnectionStatsCard(),
                      ),
                    ),
                  )
                : ListView(children: const [ConnectionStatsCard()]),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> teardownCard(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  }

  testWidgets('counts what the Core is holding open', (tester) async {
    when(() => core.getConnectionCount()).thenAnswer((_) async => 34);

    await pumpCard(tester);

    expect(find.text('34'), findsOneWidget);

    await teardownCard(tester);
  });

  testWidgets(
    'the compact desktop summary keeps all three counts in one grid cell',
    (tester) async {
      when(() => core.getConnectionCount()).thenAnswer((_) async => 99999);
      container.read(requestCountProvider.notifier).value = 123456;
      container.read(dnsQueryCountProvider.notifier).value = 42;
      for (final scale in [1.0, 1.4]) {
        await pumpCard(
          tester,
          size: const Size(1200, 800),
          density: DashboardDensity.compact,
          locale: const Locale('en'),
          textScale: scale,
        );
        expect(
          tester.getSize(find.byType(ConnectionStatsCard)),
          const Size(200, 122),
        );
        expect(find.text('99,999'), findsOneWidget);
        expect(find.text('123K'), findsOneWidget);
        expect(find.text('42'), findsOneWidget);
        final labels = ['Live connections', 'Recent requests', 'DNS queries'];
        final card = tester.getRect(find.byType(ConnectionStatsCard));
        for (var index = 0; index < labels.length; index++) {
          final rect = tester.getRect(_stat(labels[index]));
          expect(card.contains(rect.topLeft), isTrue);
          expect(card.contains(rect.bottomRight), isTrue);
          expect(find.byTooltip(labels[index]), findsOneWidget);
          if (index > 0) {
            expect(
              rect.top,
              greaterThan(tester.getRect(_stat(labels[index - 1])).bottom),
            );
          }
        }
        expect(tester.takeException(), isNull);
        await teardownCard(tester);
      }
    },
  );

  testWidgets('each compact desktop row still opens its complete feed', (
    tester,
  ) async {
    await pumpCard(
      tester,
      size: const Size(1200, 800),
      density: DashboardDensity.compact,
    );
    for (final (label, view) in [
      ('Live connections', ConnectionsView),
      ('Recent requests', RequestsView),
      ('DNS queries', DnsQueriesView),
    ]) {
      await tester.tap(_stat(label));
      await tester.pumpAndSettle();
      expect(find.byType(view), findsOneWidget);
      await tester.tapAt(const Offset(200, 20));
      await tester.pumpAndSettle();
      expect(find.byType(view), findsNothing);
    }
    await teardownCard(tester);
  });

  testWidgets('the request and DNS counts follow on the throttled cadence', (
    tester,
  ) async {
    await pumpCard(tester);

    container.read(requestCountProvider.notifier).value = 1284;
    container.read(dnsQueryCountProvider.notifier).value = 42;
    await tester.pump();

    expect(find.text('1,284'), findsNothing);
    await tester.pump(const Duration(milliseconds: 301));

    expect(find.text('1,284'), findsOneWidget);
    expect(find.text('42'), findsOneWidget);

    await teardownCard(tester);
  });

  testWidgets('a count too long for a third of a phone is shortened in any '
      'locale', (tester) async {
    when(() => core.getConnectionCount()).thenAnswer((_) async => 99999);
    container.read(requestCountProvider.notifier).value = 123456;

    await pumpCard(tester, locale: const Locale('zh', 'CN'));

    expect(find.text('99,999'), findsOneWidget);
    expect(find.text('123K'), findsOneWidget);

    await teardownCard(tester);
  });

  testWidgets('every count opens its own list in a sheet', (tester) async {
    await pumpCard(tester);

    for (final (label, view) in [
      ('Live connections', ConnectionsView),
      ('Recent requests', RequestsView),
      ('DNS queries', DnsQueriesView),
    ]) {
      await tester.tap(_stat(label));
      await tester.pumpAndSettle();

      expect(find.byType(view), findsOneWidget);
      expect(
        tester.getTopLeft(find.byType(SheetDragHandle)).dy,
        closeTo(_mobileSize.height * (1 - snapSheetDetents.first), 1),
      );

      await tester.tapAt(const Offset(200, 20));
      await tester.pumpAndSettle();
      expect(find.byType(view), findsNothing);
    }

    await teardownCard(tester);
  });

  testWidgets('the requests sheet keeps the newest request at its top while '
      'it is dragged and requests arrive', (tester) async {
    final notifier = container.read(requestsProvider.notifier);
    var next = 0;
    while (next < 200) {
      notifier.addRequest(_request(next++));
    }
    await pumpCard(tester);
    await tester.tap(_stat('Recent requests'));
    await tester.pumpAndSettle();
    final list = find.descendant(
      of: find.byType(TrackerInfoList),
      matching: find.byType(Scrollable),
    );
    ScrollPosition position() =>
        tester.state<ScrollableState>(list.first).position;

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(SheetDragHandle)),
    );
    for (var frame = 0; frame < 40; frame++) {
      if (frame % 10 == 0) {
        for (var i = 0; i < 5; i++) {
          notifier.addRequest(_request(next++));
        }
      }
      await gesture.moveBy(const Offset(0, -6));
      await tester.pump(const Duration(milliseconds: 16));
      expect(position().pixels, position().maxScrollExtent);
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(position().pixels, position().maxScrollExtent);
    expect(find.textContaining('host-${next - 1}.test'), findsWidgets);

    await teardownCard(tester);
  });
}
