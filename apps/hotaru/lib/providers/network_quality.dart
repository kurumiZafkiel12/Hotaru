import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hotaru/common/network_quality.dart';

import 'core.dart';
import 'route_state.dart';

class NetworkQualityState {
  const NetworkQualityState({
    this.report,
    this.running = false,
    this.progress = 0,
    this.route,
  });
  final NetworkQualityReport? report;
  final bool running;
  final int progress;
  final RouteState? route;

  NetworkQualityReport? reportFor(RouteState current) {
    final sampled = route;
    final observation = report;
    return sampled != null &&
            observation != null &&
            DateTime.now().difference(observation.checkedAt).abs() <
                networkQualityMaxAge &&
            current.live &&
            current.synced &&
            current.coreEpoch == sampled.coreEpoch &&
            current.routeVersion == sampled.routeVersion &&
            current.hostEpoch == sampled.hostEpoch &&
            current.proxied == sampled.proxied
        ? observation
        : null;
  }
}

final networkQualityProvider =
    NotifierProvider<NetworkQuality, NetworkQualityState>(NetworkQuality.new);

class NetworkQuality extends Notifier<NetworkQualityState> {
  int _generation = 0;
  NetworkQualityRunner? _runner;
  Timer? _expiry;
  Timer? _automatic;
  int _watchers = 0;
  bool _automaticRun = false;

  @override
  NetworkQualityState build() {
    ref.listen(routeTrackerProvider, (before, after) {
      if (before != null && after.invalidatesDiagnostics(before)) {
        cancel(refresh: true);
      } else {
        _queueAutomatic();
      }
    });
    ref.onDispose(() {
      _generation++;
      _runner?.cancel();
      _expiry?.cancel();
      _automatic?.cancel();
    });
    return const NetworkQualityState();
  }

  void watch() {
    _watchers++;
    if (_watchers == 1) _queueAutomatic();
  }

  void unwatch() {
    if (_watchers == 0) return;
    _watchers--;
    if (_watchers == 0) {
      _automatic?.cancel();
      if (_automaticRun && state.running) cancel();
    }
  }

  void _queueAutomatic() {
    _automatic?.cancel();
    if (_watchers == 0 || state.running) return;
    final route = ref.read(routeTrackerProvider);
    if (!route.proxied ||
        !route.live ||
        !route.synced ||
        state.reportFor(route) != null) {
      return;
    }
    _automatic = Timer(const Duration(milliseconds: 500), () {
      if (ref.mounted && _watchers > 0) unawaited(_measure(automatic: true));
    });
  }

  void cancel({bool refresh = false}) {
    final generation = ++_generation;
    _runner?.cancel();
    _expiry?.cancel();
    _automatic?.cancel();
    scheduleMicrotask(() {
      if (ref.mounted && generation == _generation) {
        state = const NetworkQualityState();
        if (refresh) _queueAutomatic();
      }
    });
  }

  void stop() {
    if (ref.mounted && state.running) cancel();
  }

  Future<void> measure() => _measure(automatic: false);

  Future<void> _measure({required bool automatic}) async {
    final route = ref.read(routeTrackerProvider);
    if (state.running || !route.proxied || !route.synced || !route.live) return;
    final generation = ++_generation;
    _automatic?.cancel();
    _automaticRun = automatic;
    _expiry?.cancel();
    final runner = _runner = NetworkQualityRunner(
      probe: ref.read(coreHandlerProvider).probe,
    );
    state = const NetworkQualityState(running: true);
    try {
      final report = await runner.run(
        onProgress: (completed) {
          if (ref.mounted && generation == _generation) {
            state = NetworkQualityState(running: true, progress: completed);
          }
        },
      );
      if (!ref.mounted || generation != _generation) return;
      state = NetworkQualityState(report: report, route: route);
      _expiry = Timer(networkQualityMaxAge, () => cancel(refresh: true));
    } finally {
      if (generation == _generation) {
        _runner = null;
      }
    }
  }
}
