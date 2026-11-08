import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/common/service_probe.dart';
import 'package:hotaru/core/adapter.dart';
import 'package:hotaru/core/sing_box/service_catalog.dart';
import 'package:hotaru/core/sing_box/service_diagnostics.dart';
import 'package:hotaru/models/models.dart';

void main() {
  test('Dart service catalog covers every existing service target', () {
    expect(
      singBoxServiceEndpoints.keys.toSet(),
      ServiceTarget.values.map((item) => item.id).toSet(),
    );
  });

  test(
    'HTTP connectivity and region, challenge, authentication and unlock results remain separate',
    () async {
      expect(
        await classifyServiceResponse(
          const ProbeResult(statusCode: 403),
          connectivity: true,
        ),
        'reachable',
      );
      expect(
        await classifyServiceResponse(
          const ProbeResult(statusCode: 403, body: 'unsupported_country'),
        ),
        'unsupported-region',
      );
      expect(
        await classifyServiceResponse(
          const ProbeResult(
            statusCode: 200,
            body: '<html>verify you are human</html>',
          ),
        ),
        'challenge',
      );
      expect(
        await classifyServiceResponse(const ProbeResult(statusCode: 401)),
        'authentication-required',
      );
      expect(
        await classifyServiceResponse(
          const ProbeResult(statusCode: 200, body: 'welcome'),
        ),
        'reachable',
      );
      expect(
        await classifyServiceResponse(const ProbeResult(statusCode: 503)),
        'unavailable',
      );
      expect(
        await classifyServiceResponse(const ProbeResult(error: 'timeout')),
        'timeout',
      );
    },
  );

  test('service-specific markers keep countries and explicit restrictions', () {
    expect(serviceRegionFields('youtube', '{"GL":"JP"}', ''), (
      region: 'JP',
      unsupported: false,
    ));
    expect(
      serviceRegionFields(
        'spotify',
        '{"countryCode":"US"}',
        'https://spotify.com/en-sg/',
      ),
      (region: 'SG', unsupported: false),
    );
    expect(
      serviceRegionFields(
        'disney-plus',
        '{"countryCode":"HK","inSupportedLocation":false}',
        '',
      ),
      (region: 'HK', unsupported: true),
    );
    expect(
      serviceRegionFields(
        'prime-video',
        '{"currentTerritory":"JP","isServiceRestricted":true}',
        '',
      ),
      (region: 'JP', unsupported: true),
    );
    expect(
      serviceRegionFields(
        'tiktok',
        '{"region":"EU-TTP2","webapp.app-context":{"region":"JP"}}',
        '',
      ).region,
      'JP',
    );
  });

  test(
    'Netflix partial unlock and raw CDN tampering retain actual request evidence',
    () async {
      final urls = <String>[];
      final service = SingBoxServiceDiagnostics(
        send: (params, cancelled) async {
          urls.add(params.url);
          return (
            result: ProbeResult(
              url: params.url,
              statusCode: params.url.endsWith('70143836') ? 404 : 200,
              body: params.url.contains('raw.githubusercontent')
                  ? 'tampered'
                  : '{"isPlayable":true}',
              chains: const ['node', 'group'],
              rule: 'DOMAIN-SUFFIX',
            ),
            snapshot: const RouteSnapshot(coreEpoch: 4, routeVersion: 2),
            hits: [
              RouteHit(host: Uri.parse(params.url).host, exit: 'observed'),
            ],
          );
        },
      );
      addTearDown(service.close);
      final results = await service.check(
        const ServiceCheckParams(names: ['netflix', 'github'], timeout: 5000),
      );
      expect(results[0].status, 'originals-only');
      expect(results[0].observations, hasLength(2));
      expect(results[0].hits, hasLength(1));
      expect(results[1].status, 'failed');
      expect(results[1].observations.last.error, 'content-sha256-mismatch');
      expect(urls, hasLength(4));
    },
  );

  test(
    'cancelling a run releases active requests and prevents queued services from starting',
    () async {
      final started = Completer<void>();
      var calls = 0;
      final service = SingBoxServiceDiagnostics(
        send: (params, cancelled) async {
          calls++;
          if (calls == 4) started.complete();
          await cancelled;
          return (
            result: ProbeResult(
              url: params.url,
              error: 'failed',
              message: 'cancelled',
            ),
            snapshot: const RouteSnapshot(),
            hits: <RouteHit>[],
          );
        },
      );
      addTearDown(service.close);
      final pending = service.check(
        const ServiceCheckParams(
          runId: 'cancel-test',
          names: ['google', 'youtube', 'chatgpt', 'claude', 'deepseek', 'kimi'],
          timeout: 10000,
        ),
      );
      await started.future;
      expect(
        await service.check(
          const ServiceCheckParams(
            runId: 'cancel-test',
            timeout: 10000,
            cancel: true,
          ),
        ),
        isEmpty,
      );
      expect(await pending.timeout(const Duration(seconds: 1)), hasLength(6));
      expect(calls, 4);
      expect(
        await service.check(
          const ServiceCheckParams(
            runId: 'cancel-test',
            names: ['google'],
            timeout: 1000,
          ),
        ),
        isEmpty,
      );
      service.close();
      await expectLater(
        service.check(const ServiceCheckParams(timeout: 1000)),
        throwsA(isA<CoreAdapterException>()),
      );
    },
  );
}
