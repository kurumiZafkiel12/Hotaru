import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/common/browser_leak_result.dart';
import 'package:hotaru/common/dns_leak.dart';
import 'package:hotaru/features/browser_diagnostics/browser_leak_probe.dart';
import 'package:hotaru/l10n/l10n.dart';
import 'package:hotaru/models/models.dart';
import 'package:hotaru/providers/providers.dart';
import 'package:hotaru/state.dart';
import 'package:hotaru/views/network_diagnostics.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/app_paths.dart';
import '../helpers/test_app.dart';

class _Probe extends BrowserLeakProbe {
  final reply = Completer<BrowserLeakResult>();
  bool cancelled = false;
  Error? failure;
  @override
  Future<BrowserLeakResult> run(
    BrowserLeakKind kind,
    String temporaryPath,
  ) async {
    if (failure case final error?) throw error;
    return reply.future;
  }

  @override
  void cancel() => cancelled = true;
}

void main() {
  late Directory directory;
  late ProviderContainer container;
  late _Probe probe;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('browser_ui_');
    await useAppPaths(directory);
    probe = _Probe();
    container = ProviderContainer(
      overrides: [
        routeTrackerProvider.overrideWithBuild(
          (_, _) =>
              const RouteState(coreEpoch: 7, routeVersion: 2, synced: true),
        ),
      ],
    );
    globalState.container = container;
  });
  tearDown(() async {
    container.dispose();
    await directory.delete(recursive: true);
  });

  Future<void> pump(
    WidgetTester tester,
    NetworkDiagnostic kind, {
    Locale locale = const Locale('en'),
  }) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TestApp(
          locale: locale,
          child: NetworkDiagnosticsView(
            kind: kind,
            browserProbeFactory: () => probe,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final locale in AppLocalizations.delegate.supportedLocales) {
    testWidgets(
      'browser DNS results use app language ${locale.languageCode} without a running Core',
      (tester) async {
        await pump(tester, NetworkDiagnostic.dns, locale: locale);
        final strings = await AppLocalizations.load(locale);
        await tester.tap(find.widgetWithText(FilledButton, strings.start));
        probe.reply.complete(
          const BrowserLeakResult(
            kind: BrowserLeakKind.dns,
            completed: true,
            resolvers: [
              DnsResolverReceipt(
                ip: '8.8.8.8',
                country: 'US',
                organization: 'Google',
              ),
            ],
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pumpAndSettle();
        expect(find.text(strings.browserDnsObserved), findsOneWidget);
        expect(find.text('8.8.8.8'), findsOneWidget);
        expect(find.byType(DropdownButton<int>), findsNothing);
        container
            .read(routeTrackerProvider.notifier)
            .applySnapshot(const RouteSnapshot(coreEpoch: 7, routeVersion: 3));
        await tester.pumpAndSettle();
        expect(find.text(strings.browserDnsObserved), findsOneWidget);
        expect(find.text(strings.auditStale), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(probe.cancelled, isTrue);
      },
    );
  }

  testWidgets('cancelled browser work cannot restore a late result', (
    tester,
  ) async {
    await pump(tester, NetworkDiagnostic.stun);
    await tester.tap(find.widgetWithText(FilledButton, 'Start'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Cancel'));
    probe.reply.complete(
      const BrowserLeakResult(
        kind: BrowserLeakKind.webrtc,
        completed: true,
        supported: true,
        remote: ['8.8.8.8'],
        public: ['8.8.8.8'],
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pumpAndSettle();
    expect(probe.cancelled, isTrue);
    expect(find.textContaining('WebRTC public IP:'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('missing runtime or blocked webpage shows a localized failure', (
    tester,
  ) async {
    await pump(tester, NetworkDiagnostic.stun);
    probe.failure = UnsupportedError('runtime unavailable');
    await tester.tap(find.widgetWithText(FilledButton, 'Start'));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Check BrowserLeaks connectivity'),
      findsOneWidget,
    );
    expect(find.text('No mismatch in this sample'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
