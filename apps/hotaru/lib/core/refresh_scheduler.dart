import 'dart:async';

final class CoreScheduledRefresh {
  final String key;
  final DateTime loadedAt;
  final Duration interval;
  final Future<void> Function() refresh;

  const CoreScheduledRefresh({
    required this.key,
    required this.loadedAt,
    required this.interval,
    required this.refresh,
  });
}

final class CoreRefreshScheduler {
  final Future<List<CoreScheduledRefresh>> Function() entries;
  final void Function(Object, StackTrace) onError;
  final DateTime Function() clock;
  final Duration retryDelay;
  final _attempts = <String, DateTime>{};
  Timer? _timer;
  Future<void>? _running;
  bool _closed = false;

  CoreRefreshScheduler({
    required this.entries,
    required this.onError,
    DateTime Function()? clock,
    this.retryDelay = const Duration(minutes: 1),
    Duration? pollInterval = const Duration(seconds: 30),
  }) : clock = clock ?? DateTime.now {
    if (pollInterval != null) {
      _timer = Timer.periodic(pollInterval, (_) => unawaited(tick()));
    }
  }

  Future<void> tick() {
    if (_closed) return Future.value();
    return _running ??= _tick().whenComplete(() => _running = null);
  }

  Future<void> _tick() async {
    try {
      final scheduled = await entries();
      if (scheduled.length > 1024) {
        throw StateError('Too many scheduled resource refreshes');
      }
      for (final entry in scheduled) {
        if (_closed) return;
        final now = clock();
        final last = _attempts[entry.key];
        if (entry.interval <= Duration.zero ||
            now.difference(entry.loadedAt) < entry.interval ||
            last != null && now.difference(last) < retryDelay) {
          continue;
        }
        _attempts[entry.key] = now;
        while (_attempts.length > 1024) {
          _attempts.remove(_attempts.keys.first);
        }
        try {
          await entry.refresh();
          _attempts.remove(entry.key);
        } catch (error, trace) {
          onError(error, trace);
        }
      }
    } catch (error, trace) {
      onError(error, trace);
    }
  }

  Future<void> close() async {
    _closed = true;
    _timer?.cancel();
    _timer = null;
    await _running;
    _attempts.clear();
  }
}
