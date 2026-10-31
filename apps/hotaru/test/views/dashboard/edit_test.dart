import 'package:hotaru/enum/enum.dart';
import 'package:hotaru/providers/providers.dart';
import 'package:hotaru/state.dart';
import 'package:hotaru/views/dashboard/dashboard.dart';
import 'package:hotaru/views/dashboard/desktop_grid.dart';
import 'package:hotaru/views/dashboard/edit.dart';
import 'package:hotaru/views/dashboard/widgets/widgets.dart';
import 'package:hotaru/widgets/widgets.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/test_app.dart';
import '../../helpers/test_profiles.dart';

void main() {
  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer(
      overrides: [profilesProvider.overrideWith(TestProfiles.new)],
    );
    globalState.container = container;
    container.listen(appSettingProvider, (_, _) {});
  });

  tearDown(() => container.dispose());

  List<DashboardWidget> saved() =>
      container.read(appSettingProvider).dashboardWidgets;

  void seed(List<DashboardWidget> widgets) {
    container
        .read(appSettingProvider.notifier)
        .update((state) => state.copyWith(dashboardWidgets: widgets));
  }

  // The cards sway for as long as they are edited, so nothing settles.
  Future<void> settle(WidgetTester tester) async {
    for (var frame = 0; frame < 10; frame++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> pumpDashboard(
    WidgetTester tester, {
    SupportPlatform platform = SupportPlatform.Android,
    Size size = const Size(412, 1400),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    container.read(viewSizeProvider.notifier).value = size;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TestApp(child: DashboardView(platform: platform)),
      ),
    );
    await tester.pump();
  }

  Future<void> edit(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Edit dashboard'));
    await settle(tester);
  }

  Future<void> pumpEditor(
    WidgetTester tester, {
    SupportPlatform platform = SupportPlatform.Android,
    Size size = const Size(412, 1400),
  }) async {
    await pumpDashboard(tester, platform: platform, size: size);
    await edit(tester);
  }

  Future<void> teardown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
  }

  double top(WidgetTester tester, Finder finder) =>
      tester.getTopLeft(finder).dy;

  double opacityOf(WidgetTester tester, Finder card) => tester
      .widget<Opacity>(
        find.ancestor(of: card, matching: find.byType(Opacity)).first,
      )
      .opacity;

  ScrollPosition positionOf(WidgetTester tester) =>
      tester.state<ScrollableState>(find.byType(Scrollable).first).position;

  testWidgets('edits the cards themselves, in order, above the ones to add', (
    tester,
  ) async {
    seed(const [
      DashboardWidget.currentOutbound,
      DashboardWidget.proxyGroups,
      DashboardWidget.networkSpeed,
    ]);
    await pumpEditor(tester);

    expect(find.byType(DashboardEditor), findsOneWidget);
    final current = top(tester, find.byType(CurrentOutboundCard));
    final groups = top(tester, find.byType(ProxyGroupsCard));
    final speed = top(tester, find.byType(NetworkSpeedCard));
    expect(current, lessThan(groups));
    expect(groups, lessThan(speed));
    expect(speed, lessThan(top(tester, find.text('Available to add'))));
    expect(find.byTooltip('Add Memory info'), findsOneWidget);
    expect(find.byType(SortHandle), findsNothing);
    // The desktop-only card has no row on a phone.
    expect(find.byTooltip('Add Traffic takeover'), findsNothing);
    expect(tester.takeException(), isNull);

    await teardown(tester);
  });

  testWidgets('the current outbound holds the start button and stays', (
    tester,
  ) async {
    seed(const [
      DashboardWidget.currentOutbound,
      DashboardWidget.networkSpeed,
      DashboardWidget.profiles,
    ]);
    await pumpEditor(tester);

    final removeBadges = find.byWidgetPredicate(
      (widget) =>
          widget is Tooltip && (widget.message?.startsWith('Remove ') ?? false),
    );
    expect(removeBadges, findsNWidgets(2));
    expect(find.byTooltip('Remove Network speed'), findsOneWidget);
    expect(find.byTooltip('Remove Profile'), findsOneWidget);

    await teardown(tester);
  });

  testWidgets('a removed card saves at once, goes out before its room closes '
      'and can come back', (tester) async {
    seed(const [
      DashboardWidget.currentOutbound,
      DashboardWidget.networkSpeed,
      DashboardWidget.profiles,
    ]);
    await pumpEditor(tester);
    final profiles = top(tester, find.byType(ProfilesCard));

    await tester.tap(find.byTooltip('Remove Network speed'));
    await tester.pump();

    expect(saved(), const [
      DashboardWidget.currentOutbound,
      DashboardWidget.profiles,
    ]);
    final speed = find.byType(NetworkSpeedCard);
    await tester.pump(const Duration(milliseconds: 100));
    expect(opacityOf(tester, speed), inExclusiveRange(0, 1));
    expect(top(tester, find.byType(ProfilesCard)), closeTo(profiles, 4));

    await tester.pump(const Duration(milliseconds: 200));
    expect(opacityOf(tester, speed), 0);
    expect(top(tester, find.byType(ProfilesCard)), lessThan(profiles - 4));

    await settle(tester);
    expect(find.byType(NetworkSpeedCard), findsNothing);
    expect(
      top(tester, find.byTooltip('Add Network speed')),
      greaterThan(top(tester, find.text('Available to add'))),
    );

    await tester.tap(find.byTooltip('Add Network speed'));
    await settle(tester);

    expect(saved(), const [
      DashboardWidget.currentOutbound,
      DashboardWidget.profiles,
      DashboardWidget.networkSpeed,
    ]);
    expect(
      top(tester, find.byType(NetworkSpeedCard)),
      greaterThan(top(tester, find.byType(ProfilesCard))),
    );
    expect(find.byTooltip('Add Network speed'), findsNothing);

    await teardown(tester);
  });

  testWidgets('an edit keeps the cards only another platform shows', (
    tester,
  ) async {
    seed(const [
      DashboardWidget.currentOutbound,
      DashboardWidget.networkTakeover,
      DashboardWidget.networkSpeed,
      DashboardWidget.profiles,
    ]);
    await pumpEditor(tester);

    await tester.tap(find.byTooltip('Remove Network speed'));
    await tester.pump();

    expect(saved(), const [
      DashboardWidget.currentOutbound,
      DashboardWidget.networkTakeover,
      DashboardWidget.profiles,
    ]);

    await teardown(tester);
  });

  testWidgets('an added card first opens its room in view, then comes in', (
    tester,
  ) async {
    seed(const [
      DashboardWidget.currentOutbound,
      DashboardWidget.outboundMode,
      DashboardWidget.profiles,
      DashboardWidget.proxyGroups,
      DashboardWidget.serviceStatus,
    ]);
    await pumpEditor(tester, size: const Size(412, 700));
    final position = positionOf(tester);
    position.jumpTo(position.maxScrollExtent - 330);
    await tester.pump();
    final before = position.pixels;
    final speed = find.byType(NetworkSpeedCard);

    await tester.tap(find.byTooltip('Add Network speed'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(opacityOf(tester, speed), 0);
    expect(position.pixels, greaterThanOrEqualTo(before));

    await settle(tester);

    expect(opacityOf(tester, speed), 1);
    final card = tester.getRect(find.byType(NetworkSpeedCard));
    expect(card.top, greaterThan(0));
    expect(card.bottom, lessThanOrEqualTo(700 - 16 + 1));
    expect(tester.takeException(), isNull);

    await teardown(tester);
  });

  testWidgets('a card held and dragged saves the new order and keeps its '
      'state', (tester) async {
    seed(const [
      DashboardWidget.currentOutbound,
      DashboardWidget.networkSpeed,
      DashboardWidget.memoryInfo,
    ]);
    await pumpEditor(tester);
    final memory = tester.state(find.byType(MemoryInfo));
    final card = find.byType(MemoryInfo);
    final rise =
        top(tester, card) - top(tester, find.byType(NetworkSpeedCard)) - 10;

    final gesture = await tester.startGesture(tester.getCenter(card));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    for (var step = 0; step < 4; step++) {
      await gesture.moveBy(Offset(0, -rise / 4));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(MemoryInfo), findsOneWidget);
    expect(tester.state(find.byType(MemoryInfo)), same(memory));
    await gesture.up();
    await settle(tester);

    expect(saved(), const [
      DashboardWidget.currentOutbound,
      DashboardWidget.memoryInfo,
      DashboardWidget.networkSpeed,
    ]);
    expect(tester.state(find.byType(MemoryInfo)), same(memory));
    expect(tester.takeException(), isNull);

    await teardown(tester);
  });

  testWidgets('a short press neither drags nor opens a card', (tester) async {
    seed(const [
      DashboardWidget.currentOutbound,
      DashboardWidget.memoryInfo,
      DashboardWidget.profiles,
    ]);
    await pumpEditor(tester);

    await tester.tap(find.byType(MemoryInfo));
    await settle(tester);

    expect(find.byType(MemoryDetailSheet), findsNothing);
    expect(saved(), const [
      DashboardWidget.currentOutbound,
      DashboardWidget.memoryInfo,
      DashboardWidget.profiles,
    ]);

    await teardown(tester);
  });

  testWidgets('editing leaves done as the only way out in the bar', (
    tester,
  ) async {
    await pumpEditor(tester);

    expect(find.byTooltip('Done'), findsOneWidget);
    expect(find.byTooltip('Back'), findsNothing);

    await teardown(tester);
  });

  testWidgets('editing keeps the cards where they stood, state and all', (
    tester,
  ) async {
    seed(const [
      DashboardWidget.currentOutbound,
      DashboardWidget.networkSpeed,
      DashboardWidget.memoryInfo,
      DashboardWidget.profiles,
      DashboardWidget.proxyGroups,
    ]);
    await pumpDashboard(tester, size: const Size(412, 700));
    final position = positionOf(tester);
    position.jumpTo(position.maxScrollExtent / 2);
    await tester.pump();
    final offset = position.pixels;
    final memory = tester.state(find.byType(MemoryInfo, skipOffstage: false));

    await edit(tester);

    expect(find.byType(DashboardEditor), findsOneWidget);
    expect(positionOf(tester), same(position));
    expect(position.pixels, offset);
    expect(
      tester.state(find.byType(MemoryInfo, skipOffstage: false)),
      same(memory),
    );

    await tester.tap(find.byTooltip('Done'));
    await tester.pump();

    expect(find.byType(DashboardEditor), findsNothing);
    expect(find.byTooltip('Remove Network speed'), findsNothing);
    expect(find.byTooltip('Edit dashboard'), findsOneWidget);
    expect(position.pixels, offset);
    expect(
      tester.state(find.byType(MemoryInfo, skipOffstage: false)),
      same(memory),
    );

    await teardown(tester);
  });

  testWidgets('the scroll end holds still while the cards are edited', (
    tester,
  ) async {
    await pumpEditor(tester, size: const Size(412, 700));
    final position = positionOf(tester);
    final end = position.maxScrollExtent;
    expect(end, greaterThan(0));

    final gesture = await tester.startGesture(const Offset(200, 500));
    while (position.pixels < end) {
      await gesture.moveBy(const Offset(0, -40));
      await tester.pump(const Duration(milliseconds: 16));
      expect(position.maxScrollExtent, end);
    }
    await gesture.up();
    await tester.pump(const Duration(seconds: 2));
    expect(position.pixels, end);

    await teardown(tester);
  });

  testWidgets(
    'desktop edge scrolling stops on drag cancellation without saving a draft',
    (tester) async {
      const original = [
        DashboardWidget.currentOutbound,
        DashboardWidget.networkSpeed,
        DashboardWidget.networkTakeover,
        DashboardWidget.outboundMode,
        DashboardWidget.profiles,
        DashboardWidget.memoryInfo,
      ];
      seed(original);
      await pumpEditor(
        tester,
        platform: SupportPlatform.Windows,
        size: const Size(620, 500),
      );
      final position = positionOf(tester);
      expect(position.maxScrollExtent, greaterThan(0));
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(CurrentOutboundCard)),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(0, 24));
      await tester.pump(const Duration(milliseconds: 16));
      await gesture.moveTo(const Offset(300, 488));
      for (var frame = 0; frame < 12; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(position.pixels, greaterThan(20));
      expect(saved(), original);
      await gesture.cancel();
      await settle(tester);
      final stopped = position.pixels;
      await tester.pump(const Duration(milliseconds: 300));
      expect(position.pixels, stopped);
      position.jumpTo(0);
      await tester.pump();
      await tester.tap(find.text('Cancel'));
      await settle(tester);
      expect(saved(), original);
      expect(tester.takeException(), isNull);
      await teardown(tester);
    },
  );

  testWidgets('narrow desktop uses its fixed grid and mouse reordering', (
    tester,
  ) async {
    seed(const [
      DashboardWidget.currentOutbound,
      DashboardWidget.networkTakeover,
      DashboardWidget.profiles,
    ]);
    await pumpEditor(
      tester,
      platform: SupportPlatform.Windows,
      size: const Size(620, 1400),
    );
    expect(find.byType(DesktopDashboardEditor), findsOneWidget);
    expect(find.byType(DashboardEditor), findsNothing);
    expect(tester.getSize(find.byType(CurrentOutboundCard)).height, 154);
    final source = tester.getCenter(find.byType(ProfilesCard));
    final target =
        tester.getCenter(find.byType(NetworkTakeoverTile).first) -
        const Offset(40, 0);
    final gesture = await tester.startGesture(
      source,
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(0, -24));
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.moveTo(target);
    await settle(tester);
    await gesture.up();
    await settle(tester);
    await tester.tap(find.text('Done'));
    await settle(tester);
    expect(saved(), const [
      DashboardWidget.currentOutbound,
      DashboardWidget.profiles,
      DashboardWidget.systemProxy,
      DashboardWidget.tun,
    ]);
    expect(tester.takeException(), isNull);
    await teardown(tester);
  });

  testWidgets('phone rotation keeps the independent touch editor', (
    tester,
  ) async {
    seed(const [DashboardWidget.currentOutbound, DashboardWidget.vpnButton]);
    await pumpEditor(tester);
    final state = tester.state(find.byType(DashboardEditor));
    for (final size in [const Size(915, 412), const Size(412, 1400)]) {
      tester.view.physicalSize = size;
      container.read(viewSizeProvider.notifier).value = size;
      await settle(tester);
      expect(find.byType(DesktopDashboardEditor), findsNothing);
      expect(tester.state(find.byType(DashboardEditor)), same(state));
      expect(tester.takeException(), isNull);
    }
    await teardown(tester);
  });

  testWidgets('the desktop grid renders the saved cards and edits them', (
    tester,
  ) async {
    seed(const [DashboardWidget.currentOutbound, DashboardWidget.networkSpeed]);
    await pumpDashboard(
      tester,
      platform: SupportPlatform.MacOS,
      size: const Size(1220, 900),
    );

    expect(find.byTooltip('Edit dashboard'), findsOneWidget);
    expect(find.byType(DesktopDashboardGrid), findsOneWidget);
    expect(find.byType(SpeedCard), findsNWidgets(2));

    await edit(tester);
    expect(find.byType(DesktopDashboardEditor), findsOneWidget);
    expect(find.byType(DashboardEditor), findsNothing);

    await teardown(tester);
  });

  testWidgets('desktop editing keeps fixed heights and saves discrete widths', (
    tester,
  ) async {
    seed(const [DashboardWidget.currentOutbound, DashboardWidget.networkSpeed]);
    await pumpEditor(
      tester,
      platform: SupportPlatform.Windows,
      size: const Size(1220, 900),
    );
    expect(find.byKey(const ValueKey('resize-currentOutbound')), findsNothing);
    final before = tester.getRect(find.byType(CurrentOutboundCard));
    expect(before.height, 154);
    await tester.tap(find.text('Done'));
    await settle(tester);
    expect(
      container
          .read(appSettingProvider)
          .dashboardWidgetSpans['desktop.width.currentOutbound'],
      2,
    );
    expect(tester.takeException(), isNull);
    await teardown(tester);
  });
}
