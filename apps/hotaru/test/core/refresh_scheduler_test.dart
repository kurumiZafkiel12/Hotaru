import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/refresh_scheduler.dart';

void main() {
  test(
    'successful refresh follows its interval rather than the failure backoff',
    () async {
      var now = DateTime.utc(2026, 11, 9);
      var loaded = now.subtract(const Duration(minutes: 1));
      var calls = 0;
      final scheduler = CoreRefreshScheduler(
        pollInterval: null,
        clock: () => now,
        entries: () async => [
          CoreScheduledRefresh(
            key: 'short-interval',
            loadedAt: loaded,
            interval: const Duration(seconds: 10),
            refresh: () async {
              calls++;
              loaded = now;
            },
          ),
        ],
        onError: (error, _) => fail('$error'),
      );
      await scheduler.tick();
      now = now.add(const Duration(seconds: 15));
      await scheduler.tick();
      expect(calls, 2);
      await scheduler.close();
    },
  );

  test(
    'refreshes due resources once, coalesces ticks and backs off after failure',
    () async {
      var now = DateTime.utc(2026, 11, 9);
      final gate = Completer<void>();
      var calls = 0;
      final errors = <Object>[];
      final scheduler = CoreRefreshScheduler(
        pollInterval: null,
        clock: () => now,
        entries: () async => [
          CoreScheduledRefresh(
            key: 'resource',
            loadedAt: now.subtract(const Duration(hours: 2)),
            interval: const Duration(hours: 1),
            refresh: () async {
              calls++;
              await gate.future;
              throw StateError('offline');
            },
          ),
        ],
        onError: (error, _) => errors.add(error),
      );
      final first = scheduler.tick();
      final second = scheduler.tick();
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
      gate.complete();
      await Future.wait([first, second]);
      expect(errors, hasLength(1));
      await scheduler.tick();
      expect(calls, 1);
      now = now.add(const Duration(minutes: 1));
      await scheduler.tick();
      expect(calls, 2);
      await scheduler.close();
      await scheduler.tick();
      expect(calls, 2);
    },
  );

  test(
    'fresh and disabled resources do not refresh, close cancels later work',
    () async {
      final now = DateTime.utc(2026, 11, 9);
      final gate = Completer<void>();
      var calls = 0;
      final scheduler = CoreRefreshScheduler(
        pollInterval: null,
        clock: () => now,
        onError: (error, _) => fail('$error'),
        entries: () async => [
          CoreScheduledRefresh(
            key: 'fresh',
            loadedAt: now,
            interval: const Duration(hours: 1),
            refresh: () async {
              fail('fresh');
            },
          ),
          CoreScheduledRefresh(
            key: 'disabled',
            loadedAt: DateTime.utc(2020),
            interval: Duration.zero,
            refresh: () async {
              fail('disabled');
            },
          ),
          CoreScheduledRefresh(
            key: 'active',
            loadedAt: DateTime.utc(2020),
            interval: const Duration(hours: 1),
            refresh: () async {
              calls++;
              await gate.future;
            },
          ),
          CoreScheduledRefresh(
            key: 'later',
            loadedAt: DateTime.utc(2020),
            interval: const Duration(hours: 1),
            refresh: () async {
              fail('closed');
            },
          ),
        ],
      );
      final pending = scheduler.tick();
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
      final closing = scheduler.close();
      gate.complete();
      await Future.wait([pending, closing]);
    },
  );
}
