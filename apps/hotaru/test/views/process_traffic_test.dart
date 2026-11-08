import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/controller.dart';
import 'package:hotaru/core/interface.dart';
import 'package:hotaru/core/telemetry.dart';
import 'package:hotaru/l10n/l10n.dart';
import 'package:hotaru/providers/core.dart';
import 'package:hotaru/state.dart';
import 'package:hotaru/views/process_traffic.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

import '../helpers/test_app.dart';

class _Source extends Mock
    implements CoreHandlerInterface, CoreProcessTrafficSource {}

class _Legacy extends Mock implements CoreHandlerInterface {}

CoreProcessTraffic _traffic({
  bool overflow = false,
  int unknown = 0,
  List<CoreProcessCounter>? entries,
}) => CoreProcessTraffic(
  sampledAt: DateTime.utc(2026, 11, 8),
  capacity: 1024,
  overflow: overflow,
  unattributedUpload: unknown,
  unattributedDownload: 0,
  entries:
      entries ??
      const [
        CoreProcessCounter(
          pid: 11,
          path: r'C:\Apps\browser.exe',
          upload: 100,
          download: 200,
        ),
        CoreProcessCounter(
          pid: 12,
          path: r'C:\Apps\browser.exe',
          upload: 300,
          download: 400,
        ),
        CoreProcessCounter(
          pid: 13,
          path: r'C:\Apps\editor.exe',
          upload: 10,
          download: 20,
        ),
      ],
);

void main() {
  Future<void> waitFor(WidgetTester tester, Finder finder) async {
    for (var attempt = 0; attempt < 100; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
      if (finder.evaluate().isNotEmpty) {
        await tester.pump(const Duration(milliseconds: 300));
        return;
      }
    }
    expect(finder, findsWidgets);
  }

  Future<AppLocalizations> mount(
    WidgetTester tester,
    CoreHandlerInterface source, {
    Locale locale = const Locale('en'),
  }) async {
    tester.view.physicalSize = const Size(460, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final container = ProviderContainer(
      overrides: [
        coreHandlerProvider.overrideWithValue(CoreController.scoped(source)),
      ],
    );
    globalState.container = container;
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TestApp(locale: locale, child: const ProcessTrafficView()),
      ),
    );
    await waitFor(tester, find.byType(ProcessTrafficView));
    return AppLocalizations.of(tester.element(find.byType(ProcessTrafficView)));
  }

  for (final locale in AppLocalizations.delegate.supportedLocales) {
    testWidgets('application and process ranking stays compact in $locale', (
      tester,
    ) async {
      final source = _Source();
      when(source.getProcessTraffic).thenAnswer((_) async => _traffic());
      final l10n = await mount(tester, source, locale: locale);
      await waitFor(tester, find.text('browser.exe'));
      expect(find.text(l10n.processTrafficTitle), findsOneWidget);
      expect(find.text('browser.exe'), findsOneWidget);
      expect(find.text('PID 11, 12'), findsOneWidget);
      expect(find.text('editor.exe'), findsOneWidget);
      await tester.tap(find.text(l10n.processTrafficByProcess));
      await waitFor(tester, find.text('PID 11'));
      expect(find.text('browser.exe'), findsNWidgets(2));
      expect(find.text('PID 12'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'empty, unsupported, unknown and overflow have truthful separate states',
    (tester) async {
      final source = _Source();
      CoreProcessTraffic? value = _traffic(entries: []);
      when(source.getProcessTraffic).thenAnswer((_) async => value);
      final l10n = await mount(tester, source);
      await waitFor(tester, find.text(l10n.processTrafficEmpty));
      value = _traffic(entries: [], unknown: 200, overflow: true);
      await tester.pump(const Duration(seconds: 3));
      await waitFor(tester, find.text(l10n.processTrafficUnattributed));
      expect(find.text(l10n.processTrafficOverflow), findsOneWidget);
      expect(find.text(l10n.processTrafficEmpty), findsNothing);
      value = null;
      await tester.pump(const Duration(seconds: 3));
      await waitFor(tester, find.text(l10n.processTrafficUnavailable));
      expect(find.text(l10n.processTrafficUnattributed), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('legacy core is explained without calling unsupported methods', (
    tester,
  ) async {
    final l10n = await mount(tester, _Legacy());
    await waitFor(tester, find.text(l10n.processTrafficUnavailable));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('read errors clear stale totals and recover on the next sample', (
    tester,
  ) async {
    final source = _Source();
    var failed = false;
    when(source.getProcessTraffic).thenAnswer((_) async {
      if (failed) throw StateError('fixture');
      return _traffic();
    });
    final l10n = await mount(tester, source);
    await waitFor(tester, find.text('browser.exe'));
    failed = true;
    await tester.pump(const Duration(seconds: 3));
    await waitFor(tester, find.text(l10n.processTrafficFailed));
    expect(find.text('browser.exe'), findsNothing);
    failed = false;
    await tester.pump(const Duration(seconds: 3));
    await waitFor(tester, find.text('browser.exe'));
    expect(find.text(l10n.processTrafficFailed), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('disposal ignores a late process snapshot', (tester) async {
    final source = _Source();
    final reply = Completer<CoreProcessTraffic?>();
    when(source.getProcessTraffic).thenAnswer((_) => reply.future);
    await mount(tester, source);
    await tester.pumpWidget(const SizedBox.shrink());
    reply.complete(_traffic());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
