import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/common/network_quality.dart';
import 'package:hotaru/models/models.dart';

ProbeResult sample(
  int delay, {
  String node = 'node-A',
  int status = 204,
  String url = networkQualityUrl,
}) => ProbeResult(
  url: url,
  statusCode: status,
  delay: delay,
  chains: [node, 'daily'],
);
NetworkQualityReport report(List<ProbeResult?> samples) => NetworkQualityReport(
  samples: samples,
  checkedAt: DateTime.utc(2026, 10, 30),
);

void main() {
  test(
    'grades repeated responses using latency, adjacent variation and failed requests',
    () {
      final excellent = report([
        for (final delay in [60, 65, 70, 70, 75, 65]) sample(delay),
      ]);
      expect(excellent.grade, NetworkQualityGrade.excellent);
      expect(excellent.medianMs, 67.5);
      expect(excellent.jitterMs, 5);
      expect(excellent.failureRate, 0);
      expect(
        report([
          for (final delay in [200, 210, 200, 220, 200, 210]) sample(delay),
        ]).grade,
        NetworkQualityGrade.good,
      );
      expect(
        report([
          sample(200),
          sample(205),
          null,
          sample(210),
          sample(215),
          sample(220),
        ]).grade,
        NetworkQualityGrade.good,
      );
      expect(
        report([for (var i = 0; i < 6; i++) sample(500)]).grade,
        NetworkQualityGrade.poor,
      );
      expect(
        report([
          for (final delay in [50, 250, 50, 250, 50, 250]) sample(delay),
        ]).grade,
        NetworkQualityGrade.poor,
      );
      expect(
        report([
          sample(60),
          null,
          sample(70),
          sample(70),
          null,
          sample(80),
        ]).grade,
        NetworkQualityGrade.poor,
      );
    },
  );

  test(
    'one fast response, insufficient samples, wrong HTTP response or changed chains cannot establish quality',
    () {
      for (final samples in <List<ProbeResult?>>[
        [sample(1)],
        [sample(10), sample(20), null, null, null, null],
        [for (var i = 0; i < 6; i++) sample(10, status: 200)],
        [
          for (var i = 0; i < 6; i++)
            sample(10, url: 'https://portal.example/'),
        ],
        [
          for (var i = 0; i < 6; i++)
            sample(10, node: i == 3 ? 'node-B' : 'node-A'),
        ],
        [
          for (var i = 0; i < 6; i++)
            const ProbeResult(
              url: networkQualityUrl,
              statusCode: 204,
              delay: 10,
            ),
        ],
      ]) {
        expect(report(samples).grade, NetworkQualityGrade.unknown);
      }
    },
  );

  test(
    'runner makes exactly six bounded current-rule requests to the same target',
    () async {
      final calls = <ProbeParams>[];
      final progress = <int>[];
      final result = await NetworkQualityRunner(
        pause: Duration.zero,
        probe: (params) async {
          calls.add(params);
          return sample(100);
        },
      ).run(onProgress: progress.add);
      expect(calls, hasLength(6));
      expect(
        calls.every(
          (params) =>
              params.url == networkQualityUrl &&
              params.proxyName.isEmpty &&
              params.timeout == 3000,
        ),
        isTrue,
      );
      expect(progress, [1, 2, 3, 4, 5, 6]);
      expect(result?.grade, NetworkQualityGrade.excellent);
    },
  );

  test(
    'cancelling suppresses the late response and remaining requests',
    () async {
      final pending = Completer<ProbeResult?>();
      var calls = 0;
      final runner = NetworkQualityRunner(
        pause: Duration.zero,
        probe: (_) {
          calls++;
          return pending.future;
        },
      );
      final running = runner.run();
      runner.cancel();
      pending.complete(sample(10));
      expect(await running, isNull);
      expect(calls, 1);
    },
  );
}
