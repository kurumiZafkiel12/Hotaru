import 'dart:async';
import 'dart:convert';

import 'package:hotaru/common/ip_portrait.dart';
import 'package:hotaru/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fixtures/ip_portrait.dart';

final _time = DateTime.utc(2026, 10, 30);

void main() {
  test(
    'missing type and flags remain unknown rather than residential or clean',
    () {
      final answer = IpPortraitObservation.parse(
        IpPortraitSource.ipQuery,
        '8.8.8.8',
        '{"ip":"8.8.8.8"}',
        _time,
      );
      expect(answer.access, isEmpty);
      expect(answer.flags, isEmpty);
      expect(answer.metrics, isEmpty);
      expect(answer.checkedAt, _time);
    },
  );

  test('source risk flags, metrics and declared access stay distinct', () {
    final answer = IpPortraitObservation.parse(
      IpPortraitSource.ipApiIs,
      '8.8.8.8',
      jsonEncode(profileJson(IpPortraitSource.ipApiIs)),
      _time,
    );
    expect(answer.access, 'isp');
    expect(answer.reportsRisk, isTrue);
    expect(answer.flags['proxy'], isNull);
    expect(answer.metrics, {'company.abuser_score': '0.001 (Low)'});
    final query = IpPortraitObservation.parse(
      IpPortraitSource.ipQuery,
      '8.8.8.8',
      jsonEncode(profileJson(IpPortraitSource.ipQuery)),
      _time,
    );
    expect(query.metrics['risk_score'], '0');
    expect(query.access, isEmpty);
    expect(query.reportsRisk, isFalse);
  });

  test('rejects IP mismatch, private responses and malformed metrics', () {
    for (final ip in ['1.1.1.1', '192.168.1.1', 'invalid']) {
      expect(
        () => IpPortraitObservation.parse(
          IpPortraitSource.geoJs,
          '8.8.8.8',
          jsonEncode(profileJson(IpPortraitSource.geoJs, ip: ip)),
          _time,
        ),
        throwsFormatException,
      );
    }
    final answer = IpPortraitObservation.parse(
      IpPortraitSource.ipQuery,
      '8.8.8.8',
      '{"ip":"8.8.8.8","risk":{"risk_score":-5,"is_vpn":"false"}}',
      _time,
    );
    expect(answer.flags, isEmpty);
    expect(answer.metrics, isEmpty);
  });

  test(
    'compares countries and flags for the same IP, never across address families',
    () {
      IpPortraitObservation answer(
        IpPortraitSource source,
        String ip,
        String country,
      ) => IpPortraitObservation.parse(
        source,
        ip,
        jsonEncode(profileJson(source, ip: ip, country: country)),
        _time,
      );
      final exits = [
        IpExitObservation(family: 4, ip: '8.8.8.8', checkedAt: _time),
      ];
      final report = IpPortraitReport(
        checkedAt: _time,
        exits: exits,
        sources: [
          answer(IpPortraitSource.ipQuery, '8.8.8.8', 'US'),
          answer(IpPortraitSource.ipApiIs, '8.8.8.8', 'US'),
        ],
      );
      expect(report.hasDisagreement, isTrue);
      expect(report.hasRisk, isTrue);
      final dual = IpPortraitReport(
        checkedAt: _time,
        exits: [
          ...exits,
          IpExitObservation(
            family: 6,
            ip: '2606:4700:4700::1111',
            checkedAt: _time,
          ),
        ],
        sources: [
          answer(IpPortraitSource.geoJs, '8.8.8.8', 'US'),
          answer(IpPortraitSource.geoJs, '2606:4700:4700::1111', 'AU'),
        ],
      );
      expect(dual.hasDisagreement, isFalse);
    },
  );

  test(
    'runner measures IPv4/IPv6 and requests all sources for the exact measured address',
    () async {
      final calls = <String>[];
      final routes = <ProbeParams>[];
      final runner = IpPortraitRunner(
        coreEpoch: 7,
        routeVersion: 2,
        request: (params) async {
          final url = params.urls.single;
          calls.add(url);
          expect(params.proxyName, isEmpty);
          if (url.contains('api6.ipify')) return null;
          if (Uri.parse(url).host == 'api.ipify.org') {
            return OutboundIpResult(
              url: url,
              body: '{"ip":"8.8.8.8"}',
              coreEpoch: 7,
              routeVersion: 2,
              chains: ['node-A', 'daily'],
            );
          }
          final source = IpPortraitSource.values.singleWhere(
            (source) => source.url('8.8.8.8') == url,
          );
          return OutboundIpResult(
            url: url,
            body: jsonEncode(profileJson(source)),
            coreEpoch: 7,
            routeVersion: 2,
          );
        },
        probeRoute: (params) async {
          routes.add(params);
          return ProbeResult(
            url: params.url,
            statusCode: 200,
            chains: ['node-A', 'daily'],
            rule: 'Domain',
          );
        },
      );
      final report = await runner.run();
      expect(report.addresses, ['8.8.8.8']);
      expect(report.exits.last.error, 'unavailable');
      expect(report.sources, hasLength(3));
      expect(report.routes, hasLength(3));
      expect(report.routes.first.reply?.rule, 'Domain');
      expect(calls, hasLength(5));
      expect(routes.every((params) => params.proxyName.isEmpty), isTrue);
    },
  );

  test('stale route replies do not become current IP observations', () async {
    final runner = IpPortraitRunner(
      coreEpoch: 7,
      routeVersion: 2,
      request: (params) async => OutboundIpResult(
        url: params.urls.single,
        body: '{"ip":"8.8.8.8"}',
        coreEpoch: 8,
        routeVersion: 2,
      ),
    );
    final report = await runner.run();
    expect(report.addresses, isEmpty);
    expect(report.sources, isEmpty);
  });

  test(
    'a newer global version retains measured IPs for actual exit revalidation',
    () async {
      final runner = IpPortraitRunner(
        coreEpoch: 7,
        routeVersion: 2,
        request: (params) async {
          final url = params.urls.single;
          if (url.contains('api6.ipify')) return null;
          final source = IpPortraitSource.values
              .where((source) => source.url('8.8.8.8') == url)
              .firstOrNull;
          return OutboundIpResult(
            url: url,
            body: source == null
                ? '{"ip":"8.8.8.8"}'
                : jsonEncode(profileJson(source)),
            coreEpoch: 7,
            routeVersion: 3,
            hits: [RouteHit(host: Uri.parse(url).host, exit: 'node-A')],
          );
        },
      );
      final report = await runner.run();
      expect(report.addresses, ['8.8.8.8']);
      expect(report.needsRouteValidation, isTrue);
      expect(report.receipts, hasLength(4));
      expect(
        report.receipts.every(
          (receipt) => receipt.hits.single.exit == 'node-A',
        ),
        isTrue,
      );
    },
  );

  test(
    'cancellation suppresses late replies and further source requests',
    () async {
      final pending = <Completer<OutboundIpResult?>>[];
      final runner = IpPortraitRunner(
        coreEpoch: 7,
        routeVersion: 2,
        request: (params) {
          final completer = Completer<OutboundIpResult?>();
          pending.add(completer);
          return completer.future;
        },
      );
      final running = runner.run();
      runner.cancel();
      for (final item in pending) {
        item.complete(null);
      }
      final report = await running;
      expect(pending, hasLength(2));
      expect(report.addresses, isEmpty);
      expect(report.sources, isEmpty);
    },
  );
}
