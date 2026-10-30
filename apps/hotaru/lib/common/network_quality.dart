import 'dart:async';
import 'dart:convert';

import 'package:hotaru/models/models.dart';

const networkQualityUrl = 'https://www.gstatic.com/generate_204';
const networkQualityRounds = 6;
const networkQualityMaxAge = Duration(minutes: 5);

enum NetworkQualityGrade { excellent, good, poor, unknown }

class NetworkQualityReport {
  NetworkQualityReport({
    required List<ProbeResult?> samples,
    required this.checkedAt,
  }) : samples = List.unmodifiable(samples);

  final List<ProbeResult?> samples;
  final DateTime checkedAt;
  bool _usable(ProbeResult? sample) =>
      sample != null &&
      sample.error == null &&
      sample.url == networkQualityUrl &&
      sample.statusCode == 204 &&
      sample.delay > 0;
  List<int> get delays => [
    for (final sample in samples)
      if (_usable(sample)) sample!.delay,
  ];
  int get completed => samples.where(_usable).length;
  double get failureRate =>
      samples.isEmpty ? 0 : (samples.length - completed) / samples.length;
  List<String> get chains =>
      samples.where(_usable).firstOrNull?.chains ?? const [];
  bool get stableRoute {
    final paths = samples
        .where(_usable)
        .map((sample) => jsonEncode(sample!.chains))
        .toSet();
    return paths.length == 1 && chains.isNotEmpty;
  }

  double? get medianMs {
    final sorted = delays..sort();
    if (sorted.isEmpty) return null;
    final middle = sorted.length ~/ 2;
    return sorted.length.isEven
        ? (sorted[middle - 1] + sorted[middle]) / 2
        : sorted[middle].toDouble();
  }

  double? get jitterMs {
    final differences = <int>[];
    for (var index = 1; index < samples.length; index++) {
      if (_usable(samples[index - 1]) && _usable(samples[index])) {
        differences.add(
          (samples[index]!.delay - samples[index - 1]!.delay).abs(),
        );
      }
    }
    return differences.isEmpty
        ? null
        : differences.reduce((a, b) => a + b) / differences.length;
  }

  NetworkQualityGrade get grade {
    if (samples.length != networkQualityRounds ||
        completed < 3 ||
        !stableRoute) {
      return NetworkQualityGrade.unknown;
    }
    final median = medianMs!;
    final jitter = jitterMs;
    if (failureRate > 1 / networkQualityRounds ||
        median > 400 ||
        (jitter != null && jitter > 80)) {
      return NetworkQualityGrade.poor;
    }
    if (jitter == null) return NetworkQualityGrade.unknown;
    if (completed == networkQualityRounds && median <= 150 && jitter <= 30) {
      return NetworkQualityGrade.excellent;
    }
    return NetworkQualityGrade.good;
  }
}

class NetworkQualityRunner {
  NetworkQualityRunner({
    required this.probe,
    this.pause = const Duration(milliseconds: 150),
  });
  final Future<ProbeResult?> Function(ProbeParams) probe;
  final Duration pause;
  bool _cancelled = false;
  void cancel() => _cancelled = true;

  Future<NetworkQualityReport?> run({
    void Function(int completed)? onProgress,
  }) async {
    final samples = <ProbeResult?>[];
    for (var round = 0; round < networkQualityRounds && !_cancelled; round++) {
      ProbeResult? reply;
      try {
        reply = await probe(
          const ProbeParams(
            url: networkQualityUrl,
            timeout: 3000,
            maxBody: 1024,
          ),
        );
      } catch (_) {
        reply = null;
      }
      if (_cancelled) return null;
      samples.add(reply);
      onProgress?.call(samples.length);
      if (round < networkQualityRounds - 1 && pause > Duration.zero) {
        await Future<void>.delayed(pause);
      }
    }
    return _cancelled
        ? null
        : NetworkQualityReport(samples: samples, checkedAt: DateTime.now());
  }
}
