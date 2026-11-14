import '../../models/models.dart';
import '../adapter.dart';
import '../desktop/model.dart';
import '../telemetry.dart';
import 'config_preparation.dart';
import 'desktop_core.dart';

final class _TrafficSample {
  final int upload;
  final int download;
  final Duration elapsed;

  const _TrafficSample(this.upload, this.download, this.elapsed);
}

final class SingBoxUiTraffic {
  final SingBoxDesktopCore core;
  late final Duration Function() _elapsed;
  Future<void> _tail = Future.value();
  bool _closed = false;
  String? _session;
  AcceptedSingBoxConfig? _configuration;
  _TrafficSample? _last;
  _TrafficSample? _rate;
  int _uploadOffset = 0;
  int _downloadOffset = 0;

  SingBoxUiTraffic({required this.core, Duration Function()? elapsed}) {
    final watch = Stopwatch()..start();
    _elapsed = elapsed ?? (() => watch.elapsed);
  }

  Future<T> _run<T>(Future<T> Function() action) {
    final result = _tail.then((_) {
      if (_closed) throw const CoreAdapterException('closed');
      return action();
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<_TrafficSample> _read() async {
    final before = core.lifecycle.state;
    final configuration = core.configuration;
    if (before is! DesktopCoreRunning || configuration == null) {
      throw const CoreAdapterException('core_not_running');
    }
    final source = core.adapter;
    if (source is! CoreTelemetry) {
      throw const CoreAdapterException('telemetry_unavailable');
    }
    final observed = await (source as CoreTelemetry).telemetry();
    if (_closed) throw const CoreAdapterException('closed');
    final after = core.lifecycle.state;
    if (after is! DesktopCoreRunning ||
        after.session.sessionId != before.session.sessionId ||
        !identical(configuration, core.configuration)) {
      throw const CoreAdapterException('session_changed');
    }
    if (_session != before.session.sessionId ||
        !identical(_configuration, configuration)) {
      _session = before.session.sessionId;
      _configuration = configuration;
      _last = null;
      _rate = null;
      _uploadOffset = _downloadOffset = 0;
    }
    final sample = _TrafficSample(
      observed.uploadTotal,
      observed.downloadTotal,
      _elapsed(),
    );
    final previous = _last;
    if (previous != null &&
        (sample.upload < previous.upload ||
            sample.download < previous.download)) {
      throw const CoreAdapterException('traffic_counter_regressed');
    }
    _last = sample;
    return sample;
  }

  void _checkFilter(bool onlyProxy) {
    if (onlyProxy) {
      throw const CoreAdapterException('proxy_only_traffic_unavailable');
    }
  }

  Future<Traffic> total(bool onlyProxy) => _run(() async {
    _checkFilter(onlyProxy);
    final sample = await _read();
    return Traffic(
      up: sample.upload - _uploadOffset,
      down: sample.download - _downloadOffset,
    );
  });

  Future<Traffic> speed(bool onlyProxy) => _run(() async {
    _checkFilter(onlyProxy);
    final sample = await _read();
    final previous = _rate;
    if (previous == null) {
      _rate = sample;
      return const Traffic();
    }
    final micros = (sample.elapsed - previous.elapsed).inMicroseconds;
    if (micros < 1) return const Traffic();
    _rate = sample;
    return Traffic(
      up:
          (sample.upload - previous.upload).toDouble() *
          Duration.microsecondsPerSecond /
          micros,
      down:
          (sample.download - previous.download).toDouble() *
          Duration.microsecondsPerSecond /
          micros,
    );
  });

  Future<void> reset() => _run(() async {
    final sample = await _read();
    _uploadOffset = sample.upload;
    _downloadOffset = sample.download;
    _rate = sample;
  });

  Future<void> close() {
    _closed = true;
    return _tail;
  }
}
