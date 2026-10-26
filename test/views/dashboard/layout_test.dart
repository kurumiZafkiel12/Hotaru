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
    expect(of(1039, 900), DashboardDensity.compact);
    expect(of(860, 900), DashboardDensity.compact);
    expect(of(859, 900), DashboardDensity.standard);
    expect(of(640, 900), DashboardDensity.standard);
    expect(of(640, 823), DashboardDensity.compact);
    expect(of(639, 900), DashboardDensity.mobile);
    expect(dashboardColumnsOf(860), 4);
    expect(dashboardColumnsOf(859), 2);
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
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
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

  testWidgets('the exit is a full-width compact hero above the saved widgets', (
    tester,
  ) async {
    await pumpDashboard(tester, const Size(1220, 1100));
    final hero = rectOf(tester, CurrentOutboundCard);
    final speed = rectOf(tester, NetworkSpeedCard);
    final mode = rectOf(tester, OutboundModeCard);
    expect(hero.left, 24);
    expect(hero.right, 1220 - 24);
    expect(hero.height, 188);
    expect(speed.top, hero.bottom + 16);
    expect(mode.top, speed.top);
    expect(speed.width + mode.width + 16, closeTo(hero.width, 0.01));
    expect(find.byType(ProfilesCard), findsOneWidget);
    expect(find.byType(IntranetIpCard), findsOneWidget);
    expect(find.byType(ServiceStatusCard), findsOneWidget);
    expect(find.byType(NetworkTakeoverCard), findsOneWidget);
    expect(find.byType(ConnectionStatsCard), findsOneWidget);
    expect(find.byType(ProxyGroupsCard), findsOneWidget);
    // Not in the default layout; they stay one edit away.
    expect(find.byType(MemoryInfo), findsNothing);
    expect(find.byType(ConnectionsTableCard), findsNothing);
    expect(tester.takeException(), isNull);
    await teardown(tester);
  });

  testWidgets('short windows scroll without dropping widgets', (tester) async {
    seedGroups(12);
    await pumpDashboard(tester, const Size(1220, 560));
    expect(scrollExtentOf(tester), greaterThan(0));
    // The page scrolls as one; the full proxy-groups card scrolls internally.
    expect(find.byType(Scrollable), findsWidgets);
    expect(find.byType(ConnectionStatsCard), findsOneWidget);
    expect(find.byType(ProxyGroupsCard), findsOneWidget);
    expect(find.byType(ServiceStatusCard), findsOneWidget);
    expect(find.byType(MemoryInfo), findsNothing);
    expect(tester.takeException(), isNull);
    await teardown(tester);
  });

  testWidgets('wide screens center the desktop instead of stretching cards', (
    tester,
  ) async {
    await pumpDashboard(tester, const Size(2560, 1440));
    final hero = rectOf(tester, CurrentOutboundCard);
    expect(hero.center.dx, 1280);
    expect(hero.width, 360 * 4 + 16 * 3);
    expect(scrollExtentOf(tester), 0);
    expect(tester.takeException(), isNull);
    await teardown(tester);
  });

  testWidgets('mid-width desktop retains all cards in two columns', (
    tester,
  ) async {
    await pumpDashboard(tester, const Size(800, 900));
    final hero = rectOf(tester, CurrentOutboundCard);
    expect(hero.center.dx, 400);
    expect(hero.width, lessThanOrEqualTo(752));
    expect(rectOf(tester, OutboundModeCard).width, hero.width);
    expect(find.byType(NetworkSpeedCard), findsOneWidget);
    expect(find.byType(NetworkTakeoverCard), findsOneWidget);
    expect(find.byType(IntranetIpCard), findsOneWidget);
    expect(find.byType(ProfilesCard), findsOneWidget);
    expect(find.byType(ServiceStatusCard), findsOneWidget);
    expect(find.byType(ConnectionStatsCard), findsOneWidget);
    expect(find.byType(ProxyGroupsCard), findsOneWidget);
    expect(find.byType(MemoryInfo), findsNothing);
    expect(find.byType(Scrollable), findsOneWidget);
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
    expect(hero.width, 560);
    expect(hero.center.dx, 310);
    expect(find.byType(NetworkTakeoverCard), findsOneWidget);
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
