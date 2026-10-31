import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/enum/enum.dart';
import 'package:hotaru/l10n/l10n.dart';
import 'package:hotaru/models/models.dart';
import 'package:hotaru/providers/providers.dart';
import 'package:hotaru/state.dart';
import 'package:hotaru/ui/icons/icons.dart';
import 'package:hotaru/views/tools.dart';
import 'package:hotaru/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_app.dart';

void main() {
  for (final locale in [const Locale('en'), const Locale('zh', 'CN')]) {
    for (final width in [460.0, 800.0, 1536.0]) {
      testWidgets('tool cards share one layout at $width in $locale', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 960);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final container = ProviderContainer(
          overrides: [
            moreToolsSelectorStateProvider.overrideWith(
              (_) => MoreToolsSelectorState(
                navigationItems: [
                  for (final label in [
                    PageLabel.requests,
                    PageLabel.dns,
                    PageLabel.resources,
                  ])
                    NavigationItem(
                      glyph: AppGlyphs.settings,
                      label: label,
                      builder: (_) =>
                          const Scaffold(body: Text('record destination')),
                    ),
                ],
              ),
            ),
          ],
        );
        globalState.container = container;
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: TestApp(
              locale: locale,
              child: const ToolsView(platform: SupportPlatform.Windows),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final context = tester.element(find.byType(ToolsView));
        final l10n = AppLocalizations.of(context);
        expect(find.text(l10n.serviceStatus), findsNothing);
        expect(find.text(l10n.auditTitle), findsOneWidget);
        expect(find.text(l10n.webrtcLeakTitle), findsOneWidget);
        for (var attempt = 0; attempt < 8; attempt++) {
          if (tester.getCenter(find.text(l10n.resources)).dy < 880) break;
          await tester.drag(find.byType(ListView), const Offset(0, -240));
          await tester.pumpAndSettle();
        }
        final resource = find.ancestor(
          of: find.text(l10n.resources),
          matching: find.byType(CommonCard),
        );
        final dns = find.ancestor(
          of: find.text(l10n.dnsLeakTitle),
          matching: find.byType(CommonCard),
        );
        expect(tester.getSize(resource).width, tester.getSize(dns).width);
        await tester.tap(find.text(l10n.resources));
        await tester.pumpAndSettle();
        expect(find.text('record destination'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
