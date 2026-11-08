import 'dart:async';

import 'package:hotaru/common/service_probe.dart';
import 'package:hotaru/enum/enum.dart';
import 'package:hotaru/features/ip_quality/ip_quality_sheet.dart';
import 'package:hotaru/models/ip_facts.dart';
import 'package:hotaru/models/models.dart';
import 'package:hotaru/providers/ip_facts.dart';
import 'package:hotaru/providers/ip_quality.dart';
import 'package:hotaru/providers/network_quality.dart';
import 'package:hotaru/providers/outbound_ip.dart';
import 'package:hotaru/providers/providers.dart';
import 'package:hotaru/providers/routed_probe.dart';
import 'package:hotaru/views/dashboard/layout.dart';
import 'package:hotaru/views/dashboard/widgets/current_outbound.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/test_app.dart';

const _ip = '8.8.8.8';
final _facts = IpFacts(
  ip: _ip,
  checkedAt: DateTime.utc(2026, 11, 6),
  geoCountry: 'US',
  registeredCountry: 'US',
  attribute: IpAttribute.hosting,
  riskScore: 3,
  organization: 'Google LLC',
  asn: 15169,
  locationStatus: IpFactStatus.available,
  registryStatus: IpFactStatus.available,
  scoreStatus: IpFactStatus.available,
);

Widget _app({
  Locale locale = const Locale('zh', 'CN'),
  double width = 470,
  double scale = 1,
  required Future<IpFacts> Function(Ref, String) lookup,
}) => TestApp(
  locale: locale,
  overrides: [
    profilesProvider.overrideWithValue(const []),
    suspendProvider.overrideWithValue(false),
    outboundIpProbeProvider.overrideWithBuild(
      (_, _) => const RoutedProbeState({
        routedOutbound: ProbeEntry(
          phase: ProbePhase.fresh,
          value: IpInfo(ip: _ip, countryCode: 'US'),
        ),
      }),
    ),
    ipFactsProvider.overrideWith(lookup),
    ipQualityProvider.overrideWith(
      (_, _) => throw StateError('Legacy quality must not be queried'),
    ),
    networkQualityProvider.overrideWithBuild(
      (_, _) => throw StateError('Latency must not be queried'),
    ),
  ],
  homeBuilder: (child) => Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: child,
    ),
  ),
  child: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: width,
        height: 154,
        child: DashboardDensityScope(
          density: DashboardDensity.compact,
          scale: scale,
          child: const CurrentOutboundCard(platform: SupportPlatform.Windows),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets(
    'Windows status and IP sheet share exactly one result, with score source',
    (tester) async {
      var queries = 0;
      await tester.pumpWidget(
        _app(
          lookup: (_, _) async {
            queries++;
            return _facts;
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('IP来源'), findsOneWidget);
      expect(find.text('IP属性'), findsOneWidget);
      expect(find.text('IP质量'), findsOneWidget);
      expect(find.text('原生'), findsOneWidget);
      expect(find.text('机房'), findsOneWidget);
      expect(find.text('低风险'), findsOneWidget);
      expect(find.text('3 · Scamalytics'), findsOneWidget);
      expect(find.text('网络质量'), findsNothing);
      expect(queries, 1);
      await tester.tap(find.text(_ip));
      await tester.pumpAndSettle();
      final sheet = find.byType(IpFactsSheet);
      expect(sheet, findsOneWidget);
      expect(
        find.descendant(of: sheet, matching: find.text('低风险（Scamalytics 3 分）')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: sheet, matching: find.text('原生')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: sheet, matching: find.text('机房')),
        findsOneWidget,
      );
      await tester.drag(
        find.descendant(of: sheet, matching: find.byType(ListView)),
        const Offset(0, -250),
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: sheet, matching: find.text('Google LLC')),
        findsOneWidget,
      );
      expect(find.text('命中标记'), findsNothing);
      expect(queries, 1);
      expect(tester.takeException(), isNull);
    },
  );

  for (final locale in const [
    Locale('en'),
    Locale('zh', 'CN'),
    Locale('ja'),
    Locale('ru'),
    Locale('fr'),
    Locale('es'),
    Locale('ko'),
  ]) {
    for (final width in [390.0, 470.0, 650.0]) {
      testWidgets(
        'fixed-height Windows card stays readable in $locale at width $width',
        (tester) async {
          await tester.pumpWidget(
            _app(locale: locale, width: width, lookup: (_, _) async => _facts),
          );
          await tester.pumpAndSettle();
          expect(find.text('3 · Scamalytics'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'missing score never borrows a grade from hosting or network latency',
    (tester) async {
      await tester.pumpWidget(
        _app(
          lookup: (_, _) async => _facts.copyWith(
            riskScore: null,
            scoreStatus: IpFactStatus.unavailable,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('机房'), findsOneWidget);
      expect(find.text('未知'), findsOneWidget);
      expect(find.text('低风险'), findsNothing);
      expect(find.text('3 · Scamalytics'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'lookup failure settles to unknown and disposal ignores late data',
    (tester) async {
      await tester.pumpWidget(
        _app(lookup: (_, _) async => throw StateError('unavailable')),
      );
      await tester.pumpAndSettle();
      expect(find.text('未知'), findsNWidgets(4));
      expect(tester.takeException(), isNull);
      final pending = Completer<IpFacts>();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(_app(lookup: (_, _) => pending.future));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      pending.complete(_facts);
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
}
