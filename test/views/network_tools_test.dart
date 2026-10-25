import 'package:hotaru/common/media_unlock_checker.dart';
import 'package:hotaru/common/network_diagnostics.dart';
import 'package:hotaru/ui/view_scope.dart';
import 'package:hotaru/models/media_unlock.dart';
import 'package:hotaru/views/media_availability.dart';
import 'package:hotaru/views/network_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_app.dart';

class _Diagnostics extends NetworkDiagnostics {
  @override
  Future<String> run(DiagnosticKind kind, String input) async {
    throw const FormatException('offline');
  }
}

class _Checker extends MediaUnlockChecker {
  @override
  Future<Map<MediaPlatform, MediaUnlockResult>> checkAll({
    List<MediaPlatform>? platforms,
    void Function(MediaUnlockResult result)? onProgress,
  }) async {
    throw StateError('offline');
  }
}

void main() {
  testWidgets('diagnostic errors release the run control', (tester) async {
    await tester.pumpWidget(
      TestApp(
        homeBuilder: (child) =>
            ViewScope(size: const Size(800, 600), isMobile: true, child: child),
        locale: const Locale('en'),
        child: NetworkDiagnosticsView(diagnostics: _Diagnostics()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'example.com');
    await tester.tap(find.text('Run check'));
    await tester.pumpAndSettle();
    expect(find.textContaining('offline'), findsOneWidget);
    await tester.tap(find.text('Run check'));
    await tester.pumpAndSettle();
    expect(find.textContaining('offline'), findsOneWidget);
  });

  testWidgets('service checks are opt-in and recover from errors', (
    tester,
  ) async {
    await tester.pumpWidget(
      TestApp(
        homeBuilder: (child) =>
            ViewScope(size: const Size(800, 600), isMobile: true, child: child),
        locale: const Locale('en'),
        child: MediaAvailabilityView(checker: _Checker()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('offline'), findsNothing);
    expect(find.text('openai'), findsNothing);
    await tester.tap(find.text('grok'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Run check'));
    await tester.pumpAndSettle();
    expect(find.textContaining('offline'), findsOneWidget);
  });
}
