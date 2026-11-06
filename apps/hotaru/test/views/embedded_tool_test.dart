import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/features/browser_diagnostics/tool_browser.dart';
import 'package:hotaru/features/browser_diagnostics/tool_site.dart';
import 'package:hotaru/l10n/l10n.dart';
import 'package:hotaru/providers/providers.dart';
import 'package:hotaru/state.dart';
import 'package:hotaru/views/embedded_tool.dart';
import 'package:hotaru/views/ip_tools.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_app.dart';

final class _Browser implements ToolBrowser {
  final void Function(int) progress;
  final void Function() fail;
  Completer<void>? gate;
  bool closed = false;

  _Browser(this.progress, this.fail);

  @override
  Future<void> initialize() async {
    await gate?.future;
    progress(100);
  }

  @override
  Widget build(BuildContext context) =>
      const Center(child: Text('visible web page'));

  @override
  Future<void> close() async => closed = true;
}

void main() {
  late ProviderContainer container;
  late List<_Browser> browsers;
  late List<(int, String, String)> requests;
  Completer<void>? gate;

  setUp(() {
    container = ProviderContainer(
      overrides: [
        routeTrackerProvider.overrideWithBuild(
          (_, _) => const RouteState(coreEpoch: 7, synced: true),
        ),
      ],
    );
    globalState.container = container;
    browsers = [];
    requests = [];
    gate = null;
  });
  tearDown(() => container.dispose());

  ToolBrowser factory({
    required ToolSite site,
    required int port,
    required String locale,
    required String translationScript,
    required void Function(int) onProgress,
    required void Function(Uri) onLocation,
    required void Function() onFailure,
  }) {
    requests.add((port, locale, translationScript));
    final browser = _Browser(onProgress, onFailure)..gate = gate;
    browsers.add(browser);
    return browser;
  }

  Future<void> pump(
    WidgetTester tester, {
    Locale locale = const Locale('en'),
    ToolSite site = ToolSite.dns,
  }) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TestApp(
          locale: locale,
          child: EmbeddedToolView(site: site, browserFactory: factory),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('disconnected tools do not create any network browser', (
    tester,
  ) async {
    await pump(tester);
    final l10n = AppLocalizations.of(
      tester.element(find.byType(EmbeddedToolView)),
    );
    expect(find.text(l10n.embeddedToolNeedCore), findsOneWidget);
    expect(browsers, isEmpty);
  });

  for (final locale in AppLocalizations.delegate.supportedLocales) {
    testWidgets('visible browser and labels follow $locale', (tester) async {
      container.read(runTimeProvider.notifier).value = 1;
      await pump(tester, locale: locale);
      final l10n = AppLocalizations.of(
        tester.element(find.byType(EmbeddedToolView)),
      );
      expect(find.text('visible web page'), findsOneWidget);
      expect(
        requests.single.$1,
        container.read(patchClashConfigProvider).mixedPort,
      );
      expect(requests.single.$2, locale.toLanguageTag());
      expect(requests.single.$3, contains(l10n.browserRemoteIp));
      expect(find.byTooltip(l10n.embeddedToolReload), findsOneWidget);
    });
  }

  testWidgets('port changes dispose the old browser and bind a new session', (
    tester,
  ) async {
    container.read(runTimeProvider.notifier).value = 1;
    await pump(tester);
    final first = browsers.single;
    final port = requests.single.$1 + 1;
    container
        .read(patchClashConfigProvider.notifier)
        .update((v) => v.copyWith(mixedPort: port));
    await tester.pumpAndSettle();
    expect(first.closed, isTrue);
    expect(requests.last.$1, port);
    expect(browsers.length, 2);
  });

  testWidgets('changing app language recreates the native locale and labels', (
    tester,
  ) async {
    container.read(runTimeProvider.notifier).value = 1;
    await pump(tester);
    final first = browsers.single;
    await pump(tester, locale: const Locale('zh', 'CN'));
    expect(first.closed, isTrue);
    expect(requests.last.$2, 'zh-CN');
    expect(requests.last.$3, contains('网站看到的出口 IP'));
  });

  testWidgets('a stalled initialization is closed and offers retry', (
    tester,
  ) async {
    container.read(runTimeProvider.notifier).value = 1;
    gate = Completer<void>();
    await pump(tester);
    await tester.pump(const Duration(seconds: 41));
    await tester.pumpAndSettle();
    expect(browsers.single.closed, isTrue);
    final l10n = AppLocalizations.of(
      tester.element(find.byType(EmbeddedToolView)),
    );
    expect(find.text(l10n.embeddedToolUnavailable), findsOneWidget);
    gate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('visible web page'), findsNothing);
  });

  testWidgets('stop disposes a pending browser and ignores late completion', (
    tester,
  ) async {
    container.read(runTimeProvider.notifier).value = 1;
    gate = Completer<void>();
    await pump(tester);
    final pending = browsers.single;
    container.read(runTimeProvider.notifier).value = null;
    await tester.pumpAndSettle();
    expect(pending.closed, isTrue);
    gate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('visible web page'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed page offers retry without a direct fallback', (
    tester,
  ) async {
    container.read(runTimeProvider.notifier).value = 1;
    await pump(tester);
    final first = browsers.single;
    first.fail();
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(
      tester.element(find.byType(EmbeddedToolView)),
    );
    expect(first.closed, isTrue);
    expect(find.text(l10n.embeddedToolUnavailable), findsOneWidget);
    expect(browsers.length, 1);
    await tester.tap(find.text(l10n.retry));
    await tester.pumpAndSettle();
    expect(browsers.length, 2);
    expect(requests.first.$1, requests.last.$1);
    expect(find.text('visible web page'), findsOneWidget);
  });

  testWidgets('WebRTC keeps the independent STUN blocking control', (
    tester,
  ) async {
    await pump(tester, site: ToolSite.webrtc);
    expect(find.byType(SwitchListTile), findsOneWidget);
    expect(browsers, isEmpty);
  });

  testWidgets('IP portal shows the agreed sites and opens inside the app', (
    tester,
  ) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const TestApp(child: IpToolsView()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('IPPure'), findsOneWidget);
    await tester.tap(find.text('IPPure'));
    await tester.pumpAndSettle();
    expect(find.byType(EmbeddedToolView), findsOneWidget);
    expect(browsers, isEmpty);
  });
}
