import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/config/profile.dart';
import 'package:hotaru/core/config/route_preview.dart';
import 'package:hotaru/core/controller.dart';
import 'package:hotaru/core/interface.dart';
import 'package:hotaru/l10n/l10n.dart';
import 'package:hotaru/providers/core.dart';
import 'package:hotaru/state.dart';
import 'package:hotaru/views/route_preview.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

import '../helpers/test_app.dart';

class _Preview extends Mock
    implements CoreHandlerInterface, CoreRoutePreviewSource {}

class _Legacy extends Mock implements CoreHandlerInterface {}

void main() {
  Future<AppLocalizations> mount(
    WidgetTester tester,
    CoreHandlerInterface handler, {
    Locale locale = const Locale('en'),
    double width = 900,
  }) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final container = ProviderContainer(
      overrides: [
        coreHandlerProvider.overrideWithValue(CoreController.scoped(handler)),
      ],
    );
    globalState.container = container;
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TestApp(locale: locale, child: const RoutePreviewView()),
      ),
    );
    await tester.pumpAndSettle();
    return AppLocalizations.of(tester.element(find.byType(RoutePreviewView)));
  }

  for (final locale in AppLocalizations.delegate.supportedLocales) {
    testWidgets('offline route result and labels adapt to $locale', (
      tester,
    ) async {
      final core = _Preview();
      when(() => core.previewRoute(any())).thenAnswer(
        (call) async => CoreRoutePreview(
          status: CoreRoutePreviewStatus.resolved,
          target: call.positionalArguments.single as String,
          ruleIndex: 0,
          rule: const CoreRouteRule(
            kind: CoreRuleKind.domainSuffix,
            value: 'example.com',
            action: CoreRuleAction.global,
          ),
          action: CoreRuleAction.global,
          chain: ['Hotaru GLOBAL', 'Japan'],
          hops: ['Relay', 'Japan'],
        ),
      );
      final l10n = await mount(tester, core, locale: locale, width: 460);
      expect(find.text(l10n.routePreviewTitle), findsOneWidget);
      expect(find.text(l10n.routePreviewScope), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'example.com');
      await tester.pump();
      await tester.tap(find.text(l10n.routePreviewAction));
      await tester.pumpAndSettle();
      expect(find.text(l10n.routePreviewResolved), findsOneWidget);
      expect(find.text('Hotaru GLOBAL → Japan'), findsOneWidget);
      expect(find.text('Relay → Japan'), findsOneWidget);
      expect(find.text('1 · DOMAIN-SUFFIX,example.com'), findsOneWidget);
      verify(() => core.previewRoute('example.com')).called(1);
      final field = tester.widget<TextField>(find.byType(TextField));
      field.controller!.selection = const TextSelection.collapsed(offset: 0);
      await tester.pump();
      expect(find.text('Hotaru GLOBAL → Japan'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'unsupported core shows an explanation and cannot issue a preview',
    (tester) async {
      final core = _Legacy();
      final l10n = await mount(tester, core);
      await tester.enterText(find.byType(TextField), 'example.com');
      await tester.pump();
      expect(find.text(l10n.routePreviewUnavailable), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'missing data, invalid input and rejection remain distinct from a successful route',
    (tester) async {
      final core = _Preview();
      var status = CoreRoutePreviewStatus.addressRequired;
      var rejected = false;
      when(() => core.previewRoute(any())).thenAnswer(
        (_) async => CoreRoutePreview(
          status: status,
          target: 'example.com',
          action: rejected ? CoreRuleAction.reject : null,
        ),
      );
      final l10n = await mount(tester, core);
      await tester.enterText(find.byType(TextField), 'example.com');
      await tester.pump();
      for (final (state, label) in [
        (
          CoreRoutePreviewStatus.addressRequired,
          l10n.routePreviewAddressRequired,
        ),
        (
          CoreRoutePreviewStatus.contextRequired,
          l10n.routePreviewContextRequired,
        ),
        (
          CoreRoutePreviewStatus.selectionRequired,
          l10n.routePreviewSelectionRequired,
        ),
        (CoreRoutePreviewStatus.invalidTarget, l10n.routePreviewInvalidTarget),
        (CoreRoutePreviewStatus.invalidProfile, l10n.routePreviewFailed),
      ]) {
        status = state;
        await tester.tap(find.text(l10n.routePreviewAction));
        await tester.pumpAndSettle();
        expect(find.text(label), findsOneWidget);
        expect(find.text(l10n.routePreviewPath), findsNothing);
      }
      rejected = true;
      status = CoreRoutePreviewStatus.resolved;
      await tester.tap(find.text(l10n.routePreviewAction));
      await tester.pumpAndSettle();
      expect(find.text('${l10n.blockConnection} (REJECT)'), findsOneWidget);
      expect(find.text(l10n.routePreviewHops), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'old target replies cannot replace a newer result and failures release the action',
    (tester) async {
      final core = _Preview();
      final old = Completer<CoreRoutePreview>();
      final current = Completer<CoreRoutePreview>();
      when(
        () => core.previewRoute('old.example'),
      ).thenAnswer((_) => old.future);
      when(
        () => core.previewRoute('new.example'),
      ).thenAnswer((_) => current.future);
      when(
        () => core.previewRoute('failed.example'),
      ).thenThrow(StateError('fixture'));
      final l10n = await mount(tester, core);
      await tester.enterText(find.byType(TextField), 'old.example');
      await tester.pump();
      await tester.tap(find.text(l10n.routePreviewAction));
      await tester.pump();
      expect(find.text(l10n.routePreviewRunning), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      await tester.enterText(find.byType(TextField), 'new.example');
      await tester.pump();
      await tester.tap(find.text(l10n.routePreviewAction));
      await tester.pump();
      current.complete(
        CoreRoutePreview(
          status: CoreRoutePreviewStatus.resolved,
          target: 'new.example',
          chain: ['new-node'],
        ),
      );
      await tester.pumpAndSettle();
      old.complete(
        CoreRoutePreview(
          status: CoreRoutePreviewStatus.resolved,
          target: 'old.example',
          chain: ['old-node'],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('new-node'), findsOneWidget);
      expect(find.text('old-node'), findsNothing);
      await tester.enterText(find.byType(TextField), 'failed.example');
      await tester.pump();
      expect(find.text('new-node'), findsNothing);
      await tester.tap(find.text(l10n.routePreviewAction));
      await tester.pumpAndSettle();
      expect(find.text(l10n.routePreviewFailed), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('disposing a pending preview ignores its eventual reply', (
    tester,
  ) async {
    final core = _Preview();
    final reply = Completer<CoreRoutePreview>();
    when(() => core.previewRoute(any())).thenAnswer((_) => reply.future);
    final l10n = await mount(tester, core);
    await tester.enterText(find.byType(TextField), 'example.com');
    await tester.pump();
    await tester.tap(find.text(l10n.routePreviewAction));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    reply.complete(
      CoreRoutePreview(
        status: CoreRoutePreviewStatus.resolved,
        target: 'example.com',
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
