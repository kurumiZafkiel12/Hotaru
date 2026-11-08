import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/config/profile.dart';
import 'package:hotaru/l10n/l10n.dart';
import 'package:hotaru/providers/app.dart';
import 'package:hotaru/ui/ui.dart';
import 'package:hotaru/widgets/configuration_review.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_app.dart';

void main() {
  late ConfigurationReviewData warnings;
  late ConfigurationReviewData blocked;

  setUpAll(() async {
    warnings = await ConfigurationReviewData.prepare([
      const CoreConfigIssue(
        'ip_resolution_semantics_changed',
        'rules.2',
        severity: CoreConfigIssueSeverity.warning,
      ),
      const CoreConfigIssue(
        'ip_resolution_semantics_changed',
        'rules.4',
        severity: CoreConfigIssueSeverity.warning,
      ),
    ]);
    blocked = await ConfigurationReviewData.prepare([
      const CoreConfigIssue('unsupported_field', 'document.unknown'),
      const CoreConfigIssue(
        'fallback_to_urltest',
        'proxy-groups.1',
        severity: CoreConfigIssueSeverity.warning,
      ),
    ]);
  });

  test(
    'large reports retain all counts with bounded, sanitized location samples',
    () async {
      final report = await ConfigurationReviewData.prepare([
        for (var i = 0; i < 10000; i++)
          CoreConfigIssue(
            'option_$i',
            '${'长' * 200}\nprivate',
            severity: i.isEven
                ? CoreConfigIssueSeverity.error
                : CoreConfigIssueSeverity.warning,
          ),
        const CoreConfigIssue('invalid\ncode', 'path\x00control'),
      ]);
      expect(report.errors, 5001);
      expect(report.warnings, 5000);
      expect(report.groups.length, lessThanOrEqualTo(34));
      expect(
        report.groups.fold<int>(0, (sum, group) => sum + group.count),
        10001,
      );
      expect(report.groups.first.severity, CoreConfigIssueSeverity.error);
      for (final group in report.groups) {
        expect(group.paths.length, lessThanOrEqualTo(3));
        expect(group.code, isNot(contains('\n')));
        for (final path in group.paths) {
          expect(path.runes.length, lessThanOrEqualTo(180));
          expect(path, isNot(contains(RegExp(r'[\x00-\x1f]'))));
        }
      }
      expect(() => report.groups.clear(), throwsUnsupportedError);
      expect(() => report.groups.first.paths.clear(), throwsUnsupportedError);
    },
  );

  Future<void> launch(
    WidgetTester tester,
    ConfigurationReviewData data, {
    Locale locale = const Locale('en'),
    Size size = const Size(1000, 800),
    double textScale = 1,
    ValueChanged<bool?>? answered,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      TestApp(
        locale: locale,
        overrides: [viewSizeProvider.overrideWithBuild((_, _) => size)],
        child: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                final answer = await showFloatingDialog<bool>(
                  context: context,
                  child: ConfigurationReviewDialog(data: data),
                );
                answered?.call(answer);
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  for (final locale in AppLocalizations.delegate.supportedLocales) {
    testWidgets('conversion differences and confirmation follow $locale', (
      tester,
    ) async {
      bool? answer;
      await launch(
        tester,
        warnings,
        locale: locale,
        answered: (value) => answer = value,
      );
      final l10n = AppLocalizations.of(
        tester.element(find.byType(ConfigurationReviewDialog)),
      );
      expect(find.text(l10n.configurationReviewTitle), findsOneWidget);
      expect(find.text(l10n.configurationReviewIpRules), findsOneWidget);
      expect(find.text('rules.2'), findsNothing);
      await tester.tap(find.text(l10n.configurationReviewLocations));
      await tester.pumpAndSettle();
      expect(find.textContaining('rules.2'), findsOneWidget);
      await tester.tap(find.text(l10n.configurationReviewApply));
      await tester.pumpAndSettle();
      expect(answer, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'blocking issues cannot be approved and close leaves activation false',
    (tester) async {
      bool? answer;
      await launch(tester, blocked, answered: (value) => answer = value);
      final l10n = AppLocalizations.of(
        tester.element(find.byType(ConfigurationReviewDialog)),
      );
      expect(find.text(l10n.configurationReviewBlocked), findsOneWidget);
      expect(find.text(l10n.configurationReviewApply), findsNothing);
      await tester.tap(find.text(l10n.close));
      await tester.pumpAndSettle();
      expect(answer, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in [const Size(380, 700), const Size(1536, 960)]) {
    testWidgets(
      'review scrolls at $size with large text and remains cancellable',
      (tester) async {
        bool? answer;
        await launch(
          tester,
          blocked,
          size: size,
          locale: const Locale('zh', 'CN'),
          textScale: 1.8,
          answered: (value) => answer = value,
        );
        final l10n = AppLocalizations.of(
          tester.element(find.byType(ConfigurationReviewDialog)),
        );
        expect(find.byType(SingleChildScrollView), findsWidgets);
        await tester.ensureVisible(find.text(l10n.close));
        await tester.tap(find.text(l10n.close));
        await tester.pumpAndSettle();
        expect(answer, isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
