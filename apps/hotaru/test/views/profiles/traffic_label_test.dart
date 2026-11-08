import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hotaru/common/common.dart';
import 'package:hotaru/l10n/l10n.dart';
import 'package:hotaru/models/models.dart';
import 'package:hotaru/providers/providers.dart';
import 'package:hotaru/state.dart';
import 'package:hotaru/views/profiles/profiles.dart';
import 'package:hotaru/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/test_app.dart';

void main() {
  for (final locale in AppLocalizations.delegate.supportedLocales) {
    for (final custom in [false, true]) {
      testWidgets(
        'profile total stays compact and localized in $locale; custom=$custom',
        (tester) async {
          tester.view.physicalSize = const Size(360, 300);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final stream = StreamController<ProfileTrafficValue?>.broadcast();
          addTearDown(stream.close);
          final profile =
              (custom
                      ? Profile.custom(label: 'Profile')
                      : Profile.normal(
                          label: 'Profile',
                          url: 'https://example.com/sub',
                        ))
                  .copyWith(
                    id: 1,
                    subscriptionInfo: const SubscriptionInfo(
                      upload: 1024,
                      download: 2048,
                      total: 4096,
                    ),
                  );
          final container = ProviderContainer(
            overrides: [
              profileTrafficProvider.overrideWith((_, _) => stream.stream),
              profileGroupsCountProvider.overrideWith(
                (_, _) => Stream.value(6),
              ),
              isUpdatingProvider.overrideWith((_, _) => !custom),
            ],
          );
          addTearDown(container.dispose);
          globalState.container = container;
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: TestApp(
                locale: locale,
                child: Scaffold(
                  body: Align(
                    alignment: Alignment.topCenter,
                    child: SizedBox(
                      width: 340,
                      child: ProfileItem(
                        profile: profile,
                        groupValue: 1,
                        onChanged: (_) {},
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          stream.add(null);
          await tester.pump(const Duration(milliseconds: 200));
          final before = tester.getSize(find.byType(CommonCard));
          stream.add((upload: 2048, download: 4096));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 200));
          final context = tester.element(find.byType(ProfileItem));
          final label = context.appLocalizations.profileTrafficTotal(
            6144.traffic.show,
          );
          expect(find.text(label), findsOneWidget);
          expect(
            find.byTooltip(context.appLocalizations.profileTrafficSinceImport),
            findsOneWidget,
          );
          expect(tester.getSize(find.byType(CommonCard)), before);
          if (!custom) expect(find.byType(CommonCircleLoading), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
