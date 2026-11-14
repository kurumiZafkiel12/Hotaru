import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/telemetry.dart';

import 'support/telemetry_fixture.dart';

void main() {
  test(
    'memory is optional but present observations require complete nonnegative counters',
    () {
      expect(CoreTelemetrySnapshot.fromJson(telemetryFixture()).memory, isNull);
      final sample = CoreTelemetrySnapshot.fromJson(
        telemetryFixture()..['memory'] = observedMemoryFixture(),
      );
      expect(sample.memory!.rss, 1000);
      expect(sample.memory!.heapInuse, 400);
      expect(sample.memory!.heapIdle, 100);
      expect(sample.memory!.stackInuse, 80);
      expect(sample.memory!.runtimeOther, 20);
      for (final invalid in <Object>[
        false,
        {'rss': 10},
        {...observedMemoryFixture(), 'heap_idle': -1},
        {...observedMemoryFixture(), 'rss': 1.5},
      ]) {
        expect(
          () => CoreTelemetrySnapshot.fromJson(
            telemetryFixture()..['memory'] = invalid,
          ),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'observations retain process identity, physical API chain and closed counters',
    () {
      final value = telemetryFixture()
        ..['active'] = [observedConnectionFixture()]
        ..['closed'] = [observedConnectionFixture(closed: true)];
      final snapshot = CoreTelemetrySnapshot.fromJson(value);
      expect(snapshot.uploadTotal, 10);
      expect(snapshot.active.single.processId, 42);
      expect(snapshot.active.single.processPath, r'C:\Apps\browser.exe');
      expect(snapshot.active.single.chain, ['exit', 'selected']);
      expect(snapshot.active.single.closedAt, isNull);
      expect(
        snapshot.closed.single.closedAt,
        DateTime.utc(2026, 11, 6, 11, 59, 1),
      );
      expect(() => snapshot.active.clear(), throwsUnsupportedError);
      expect(
        () => snapshot.closed.single.chain.clear(),
        throwsUnsupportedError,
      );
    },
  );

  test(
    'invalid counters, port ranges, timestamps and lifetime shapes are refused',
    () {
      for (final patch in [
        {'upload_total': -1},
        {'download_total': 2.5},
        {'history_capacity': 0},
        {'active_truncated': 'false'},
        {'sampled_at': 'not a date'},
        {
          'active': [observedConnectionFixture(closed: true)],
        },
        {
          'closed': [observedConnectionFixture()],
        },
        {
          'active': [observedConnectionFixture()..['source_port'] = 65536],
        },
        {
          'active': [
            observedConnectionFixture()..['chain'] = [42],
          ],
        },
      ]) {
        expect(
          () =>
              CoreTelemetrySnapshot.fromJson({...telemetryFixture(), ...patch}),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'excess history and missing observation fields cannot silently truncate data',
    () {
      expect(
        () => CoreTelemetrySnapshot.fromJson(
          telemetryFixture()
            ..['closed'] = List.filled(
              1001,
              observedConnectionFixture(closed: true),
            ),
        ),
        throwsFormatException,
      );
      expect(
        () => CoreObservedConnection.fromJson(
          observedConnectionFixture()..remove('process_id'),
        ),
        throwsFormatException,
      );
    },
  );
}
