import 'package:hotaru/enum/enum.dart';
import 'package:hotaru/models/models.dart';
import 'package:hotaru/providers/providers.dart';
import 'package:hotaru/state.dart';
import 'package:hotaru/views/dashboard/dashboard.dart';
import 'package:hotaru/views/dashboard/layout.dart';
import 'package:hotaru/views/dashboard/widgets/widgets.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/test_app.dart';
import '../../helpers/test_profiles.dart';

void main() {
  test('the window picks the density', () {
    DashboardDensity of(double width, double height) =>
        DashboardDensity.of(Size(width, height));

    expect(of(1220, 900), DashboardDensity.standard);
    expect(of(1220, 824), DashboardDensity.standard);
    expect(of(1220, 823), DashboardDensity.compact);
    expect(of(1220, 500), DashboardDensity.compact);
    expect(of(839, 900), DashboardDensity.compact);
    expect(of(760, 900), DashboardDensity.compact);
    expect(of(759, 900), DashboardDensity.standard);
    expect(of(640, 900), DashboardDensity.standard);
    expect(of(640, 823), DashboardDensity.compact);
    expect(of(639, 900), DashboardDensity.mobile);
    expect(dashboardColumnsOf(760), 4);
    expect(dashboardColumnsOf(759), 2);
  });

  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer(
      overrides: [profilesProvider.overrideWith(TestProfiles.new)],
    );
    globalState.container = container;
    container.listen(groupsProvider, (_, _) {});
  });

  void seedGroups(int count) {
    container.read(groupsProvider.notifier).value = [
      for (var index = 0; index < count; index++)
        Group(
          type: GroupType.Selector,
          name: 'G$index',
          hidden: false,
          all: [Proxy(name: 'N$index', type: 'ss')],
        ),
    ];
  }

  tearDown(() => container.dispose());

  Future<void> pumpDashboard(
    WidgetTester tester,
    Size size, {
    SupportPlatform platform = SupportPlatform.MacOS,
    double textScale = 1,
    double devicePixelRatio = 1,
  }) async {
    tester.view.physicalSize = size * devicePixelRatio;
    tester.view.devicePixelRatio = devicePixelRatio;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    container.read(viewSizeProvider.notifier).value = size;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TestApp(child: DashboardView(platform: platform)),
      ),
    );
    await tester.pump();
  }

  Future<void> teardown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
  }

  Rect rectOf(WidgetTester tester, Type type) =>
      tester.getRect(find.byType(type).first);

  double scrollExtentOf(WidgetTester tester) => tester
      .state<ScrollableState>(find.byType(Scrollable).first)
      .position
      .maxScrollExtent;

  for (final (size, scale) in [
    (const Size(1024, 768), 1.0),
    (const Size(740, 900), 1.0),
    (const Size(460, 900), 1.0),
    (const Size(1536, 960), 1.5),
  ]) {
    testWidgets('modular grid fits $size at text scale $scale', (tester) async {
      await pumpDashboard(
        tester,
        size,
        platform: SupportPlatform.Windows,
        textScale: scale,
      );
      expect(rectOf(tester, CurrentOutboundCard).height, 154);
      expect(tester.takeException(), isNull);
      await teardown(tester);
    });
  }

  testWidgets('modular desktop default aligns all four rows', (tester) async {
    await pumpDashboard(tester, const Size(1536, 960));
    final hero = rectOf(tester, CurrentOutboundCard);
    final speeds = find.byType(SpeedCard);
    expect(speeds, findsNWidgets(2));
    final upload = tester.getRect(speeds.at(0));
    final download = tester.getRect(speeds.at(1));
    final mode = rectOf(tester, OutboundModeCard);
    final takeover = find.byType(NetworkTakeoverTile);
    expect(takeover, findsNWidgets(2));
    expect(hero.left, 14);
    expect(hero.height, 154);
    expect(upload.height, hero.height);
    expect(upload.top, hero.top);
    expect(download.top, hero.top);
    expect(upload.left, hero.right + 10);
    expect(download.left, upload.right + 10);
    expect(download.right, 1536 - 14);
    expect(mode.top, hero.bottom + 10);
    expect(mode.height, 72);
    expect(mode.width, hero.width);
    expect(tester.getRect(takeover.first).left, upload.left);
    final service = rectOf(tester, ServiceStatusCard);
    final profile = rectOf(tester, ProfilesCard);
    final intranet = rectOf(tester, IntranetIpCard);
    final memory = rectOf(tester, MemoryInfo);
    expect(service.top, mode.bottom + 10);
    expect(profile.top, service.top);
    expect(intranet.top, service.top);
    expect(memory.top, service.top);
    final connections = rectOf(tester, ConnectionsTableCard);
    final groups = rectOf(tester, ProxyGroupsCard);
    expect(connections.height, 236);
    expect(groups.height, 236);
    expect(connections.top, service.bottom + 10);
    expect(groups.top, connections.top);
    expect(groups.left, upload.left);
    expect(groups.bottom, lessThanOrEqualTo(960));
    expect(tester.takeException(), isNull);
    await teardown(tester);
  });

  testWidgets(
    'Windows DPI changes raster size but never the three logical heights',
    (tester) async {
      for (final dpr in [1.0, 1.25, 1.5, 2.0]) {
        await pumpDashboard(
          tester,
          const Size(1220, 900),
          platform: SupportPlatform.Windows,
          devicePixelRatio: dpr,
        );
        expect(rectOf(tester, CurrentOutboundCard).height, 154);
        expect(rectOf(tester, SpeedCard).height, 154);
        expect(rectOf(tester, OutboundModeCard).height, 72);
        expect(tester.takeException(), isNull);
      }
      await teardown(tester);
    },
  );

  testWidgets(
    'width selection saves, cancels and resets without changing height',
    (tester) async {
      await pumpDashboard(
        tester,
        const Size(1440, 900),
        platform: SupportPlatform.Windows,
      );
      final hold = container.listen(appSettingProvider, (_, _) {});
      addTearDown(hold.close);
      final key = DashboardWidth.storageKey(DashboardWidget.currentOutbound);
      Future<void> editWidth(String width) async {
        await tester.tap(find.byTooltip('Edit dashboard'));
        await tester.pump(const Duration(milliseconds: 350));
        await tester.tap(find.byKey(const ValueKey('width-currentOutbound')));
        for (var frame = 0; frame < 6; frame++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.tap(
          find.widgetWithText(CheckedPopupMenuItem<DashboardWidth>, width),
        );
        for (var frame = 0; frame < 6; frame++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      await editWidth('4×');
      expect(rectOf(tester, CurrentOutboundCard).width, 1412);
      expect(rectOf(tester, CurrentOutboundCard).height, 154);
      await tester.tap(find.text('Done').last);
      for (var frame = 0; frame < 6; frame++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(container.read(appSettingProvider).dashboardWidgetSpans[key], 4);
      expect(rectOf(tester, CurrentOutboundCard).width, 1412);
      await pumpDashboard(
        tester,
        const Size(740, 900),
        platform: SupportPlatform.Windows,
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(rectOf(tester, CurrentOutboundCard).width, 712);
      expect(container.read(appSettingProvider).dashboardWidgetSpans[key], 4);
      await pumpDashboard(
        tester,
        const Size(1440, 900),
        platform: SupportPlatform.Windows,
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(rectOf(tester, CurrentOutboundCard).width, 1412);
      await editWidth('2×');
      await tester.tap(find.text('Cancel').last);
      for (var frame = 0; frame < 6; frame++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(rectOf(tester, CurrentOutboundCard).width, 1412);
      expect(container.read(appSettingProvider).dashboardWidgetSpans[key], 4);
      await tester.tap(find.byTooltip('Edit dashboard'));
      for (var frame = 0; frame < 6; frame++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.tap(find.text('Restore defaults'));
      for (var frame = 0; frame < 6; frame++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.tap(find.text('Done').last);
      for (var frame = 0; frame < 6; frame++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(rectOf(tester, CurrentOutboundCard).width, 701);
      expect(container.read(appSettingProvider).dashboardWidgetSpans[key], 2);
      expect(tester.takeException(), isNull);
      await teardown(tester);
    },
  );

  testWidgets('the title bar, grid and editor share the compact page budget', (
    tester,
  ) async {
    await pumpDashboard(
      tester,
      const Size(1440, 900),
      platform: SupportPlatform.Windows,
    );
    final before = rectOf(tester, CurrentOutboundCard);
    final bar = tester.getRect(find.byType(AppBar));
    expect(bar.width, 1440);
    expect(before.width, 701);
    expect(before.left - bar.left, 14);
    await tester.tap(find.byTooltip('Edit dashboard'));
    for (var frame = 0; frame < 6; frame++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final editing = rectOf(tester, CurrentOutboundCard);
    expect(editing.left, before.left);
    expect(editing.width, before.width);
    expect(editing.height, before.height);
    expect(tester.takeException(), isNull);
    await teardown(tester);
  });

  testWidgets(
    'four compact columns fit a medium window without a wide-card fallback',
    (tester) async {
      await pumpDashboard(
        tester,
        const Size(800, 900),
        platform: SupportPlatform.Windows,
      );
      final hero = rectOf(tester, CurrentOutboundCard);
      final speed = rectOf(tester, SpeedCard);
      expect(hero.width, lessThanOrEqualTo(412));
      expect(speed.top, hero.top);
      expect(hero.right + 10, speed.left);
      expect(tester.takeException(), isNull);
      await teardown(tester);
    },
  );

  testWidgets(
    'text scaling expands the width allowance but keeps fixed card bands',
    (tester) async {
      await pumpDashboard(
        tester,
        const Size(1600, 1000),
        platform: SupportPlatform.Windows,
        textScale: 1.4,
      );
      final hero = rectOf(tester, CurrentOutboundCard);
      expect(hero.width, greaterThan(412));
      expect(hero.width, lessThanOrEqualTo(781));
      expect(hero.height, 154);
      expect(rectOf(tester, OutboundModeCard).height, 72);
      expect(tester.takeException(), isNull);
      await teardown(tester);
    },
  );

  testWidgets('short windows scroll without dropping widgets', (tester) async {
    seedGroups(12);
    container
        .read(appSettingProvider.notifier)
        .update(
          (state) => state.copyWith(dashboardWidgets: DashboardWidget.values),
        );
    await pumpDashboard(tester, const Size(1220, 560));
    expect(scrollExtentOf(tester), greaterThan(0));
    // The page scrolls as one; the full proxy-groups card scrolls internally.
    expect(find.byType(Scrollable), findsWidgets);
    expect(find.byType(ConnectionStatsCard), findsOneWidget);
    expect(find.byType(ProxyGroupsCard), findsOneWidget);
    expect(find.byType(ServiceStatusCard), findsOneWidget);
    expect(find.byType(MemoryInfo), findsOneWidget);
    expect(tester.takeException(), isNull);
    await teardown(tester);
  });

  testWidgets('maximized workspace uses the available width', (tester) async {
    await pumpDashboard(tester, const Size(2560, 1440));
    final hero = rectOf(tester, CurrentOutboundCard);
    expect(hero.left, 14);
    expect(hero.width, 1261);
    expect(scrollExtentOf(tester), 0);
    expect(tester.takeException(), isNull);
    await teardown(tester);
  });

  testWidgets('narrow desktop keeps a bounded two-column layout', (
    tester,
  ) async {
    await pumpDashboard(tester, const Size(740, 900));
    final hero = rectOf(tester, CurrentOutboundCard);
    expect(hero.center.dx, 370);
    expect(hero.width, 712);
    expect(rectOf(tester, OutboundModeCard).width, hero.width);
    expect(find.byType(SpeedCard), findsNWidgets(2));
    expect(find.byType(NetworkTakeoverTile), findsNWidgets(2));
    expect(find.byType(IntranetIpCard), findsOneWidget);
    expect(find.byType(ProfilesCard), findsOneWidget);
    expect(find.byType(ServiceStatusCard), findsOneWidget);
    expect(find.byType(ConnectionStatsCard), findsNothing);
    expect(find.byType(ProxyGroupsCard), findsOneWidget);
    expect(find.byType(MemoryInfo), findsOneWidget);
    expect(find.byType(Scrollable), findsWidgets);
    expect(tester.takeException(), isNull);
    await teardown(tester);
  });

  testWidgets('a resize adapts on its first frame before providers catch up', (
    tester,
  ) async {
    await pumpDashboard(tester, const Size(1440, 1100));
    for (final size in const [
      Size(600, 800),
      Size(800, 900),
      Size(1440, 1100),
    ]) {
      tester.view.physicalSize = size;
      await tester.pump();
      expect(tester.takeException(), isNull, reason: '$size');
      expect(find.byType(CurrentOutboundCard), findsOneWidget);
      expect(find.byType(OutboundModeCard), findsOneWidget);
    }
    await teardown(tester);
  });

  testWidgets('large text stays readable across phone and desktop widths', (
    tester,
  ) async {
    container.listen(localIpProvider, (_, _) {});
    container.read(localIpProvider.notifier).value = '192.168.100.200';
    for (final (size, platform) in const [
      (Size(1440, 1100), SupportPlatform.MacOS),
      (Size(1000, 1000), SupportPlatform.MacOS),
      (Size(412, 915), SupportPlatform.Android),
    ]) {
      for (final scale in const [1.2, 1.4]) {
        await pumpDashboard(tester, size, platform: platform, textScale: scale);
        final clipped = [
          for (final paragraph in tester.renderObjectList<RenderParagraph>(
            find.byType(RichText),
          ))
            if (paragraph.getMaxIntrinsicHeight(paragraph.size.width) >
                paragraph.size.height + 0.5)
              paragraph.text.toPlainText(),
        ];
        if (platform != SupportPlatform.Android) {
          expect(rectOf(tester, CurrentOutboundCard).height, 154);
          expect(rectOf(tester, SpeedCard).height, 154);
          expect(rectOf(tester, OutboundModeCard).height, 72);
        }
        expect(clipped, isEmpty, reason: '$size x$scale');
        expect(tester.takeException(), isNull);
      }
    }
    await teardown(tester);
  });

  testWidgets('phone keeps the saved widget order without rewriting it', (
    tester,
  ) async {
    final saved = container.read(appSettingProvider).dashboardWidgets;
    await pumpDashboard(
      tester,
      const Size(400, 900),
      platform: SupportPlatform.Android,
    );
    final hero = rectOf(tester, CurrentOutboundCard);
    expect(hero.left, 16);
    expect(hero.right, 384);
    expect(find.byType(VpnCard), findsOneWidget);
    expect(find.byType(NetworkTakeoverCard), findsNothing);
    expect(container.read(appSettingProvider).dashboardWidgets, saved);
    expect(tester.takeException(), isNull);
    await teardown(tester);
  });

  testWidgets('narrow desktop retains takeover rather than Android VPN', (
    tester,
  ) async {
    await pumpDashboard(tester, const Size(620, 700));
    final hero = rectOf(tester, CurrentOutboundCard);
    expect(hero.width, 592);
    expect(hero.center.dx, 310);
    expect(find.byType(NetworkTakeoverTile), findsNWidgets(2));
    expect(find.byType(VpnCard), findsNothing);
    expect(tester.takeException(), isNull);
    await teardown(tester);
  });

  testWidgets('tablet uses VPN in place of desktop takeover controls', (
    tester,
  ) async {
    for (final size in const [Size(1280, 800), Size(915, 412)]) {
      await pumpDashboard(tester, size, platform: SupportPlatform.Android);
      expect(find.byType(VpnCard), findsOneWidget);
      expect(find.byType(NetworkTakeoverCard), findsNothing);
      expect(find.byType(CurrentOutboundCard), findsOneWidget);
      expect(find.byType(NetworkSpeedCard), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    await teardown(tester);
  });
}
