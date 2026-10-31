import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/l10n/l10n.dart';
import 'package:hotaru/models/models.dart';
import 'package:hotaru/providers/providers.dart';
import 'package:hotaru/state.dart';
import 'package:hotaru/views/routing_configs.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_app.dart';

void main() {
  for (final locale in AppLocalizations.delegate.supportedLocales) {
    for (final width in [360.0, 900.0]) {
      testWidgets(
        'routing configuration selection fits $locale at $width with large text',
        (tester) async {
          final first = RoutingConfig(
            id: 1,
            name: 'Rules one',
            url: 'https://example.com/one.yaml',
            updatedAt: DateTime.utc(2026),
            digest: 'one',
            ruleCount: 10,
          );
          final second = first.copyWith(
            id: 2,
            name: 'Rules two',
            digest: 'two',
          );
          final container = ProviderContainer();
          globalState.container = container;
          addTearDown(container.dispose);
          container.listen(appSettingProvider, (_, _) {});
          container.read(appSettingProvider.notifier).value = AppSettingProps(
            routingConfigs: [first, second],
            activeRoutingConfigId: 1,
          );
          tester.view.physicalSize = Size(width, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: TestApp(
                locale: locale,
                homeBuilder: (child) => Builder(
                  builder: (context) => MediaQuery(
                    data: MediaQuery.of(
                      context,
                    ).copyWith(textScaler: const TextScaler.linear(1.5)),
                    child: child,
                  ),
                ),
                child: const RoutingConfigsView(),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('Rules two'));
          await tester.pumpAndSettle();
          expect(container.read(appSettingProvider).activeRoutingConfigId, 2);
          expect(
            container.read(appSettingProvider).routingRulesEnabled,
            isFalse,
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }
}
