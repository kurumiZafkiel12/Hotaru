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

  @override
  NetworkQualityState build() {
    ref.listen(routeTrackerProvider, (before, after) {
      if (before != null &&
          (before.coreEpoch != after.coreEpoch ||
              before.routeVersion != after.routeVersion ||
              before.hostEpoch != after.hostEpoch ||
              before.proxied != after.proxied ||
              (before.synced && !after.synced))) {
        cancel();
      }
    });
    ref.onDispose(() {
      _generation++;
      _runner?.cancel();
      _expiry?.cancel();
    });
    return const NetworkQualityState();
  }

  void cancel() {
    final generation = ++_generation;
    _runner?.cancel();
    _expiry?.cancel();
    scheduleMicrotask(() {
      if (ref.mounted && generation == _generation) {
        state = const NetworkQualityState();
      }
    });
  }

  void stop() {
    if (ref.mounted && state.running) cancel();
  }

  Future<void> measure() async {
    final route = ref.read(routeTrackerProvider);
    if (state.running || !route.proxied || !route.synced || !route.live) return;
    final generation = ++_generation;
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
      _expiry = Timer(networkQualityMaxAge, cancel);
    } finally {
      if (generation == _generation) {
        _runner = null;
      }
    }
  }
}
