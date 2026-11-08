import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/telemetry.dart';
import 'package:hotaru/features/process_traffic/ranking.dart';

import 'support/telemetry_fixture.dart';

Map<String, dynamic> _source({
  List<Map<String, dynamic>> entries = const [],
  bool overflow = false,
}) => {
  'capacity': 1024,
  'overflow': overflow,
  'unattributed': {'upload': 7, 'download': 8},
  'entries': entries,
};

void main() {
  test(
    'old snapshots stay readable and raw process counters retain sample identity',
    () {
      expect(
        CoreTelemetrySnapshot.fromJson(telemetryFixture()).processes,
        isNull,
      );
      final data = CoreTelemetrySnapshot.fromJson(
        telemetryFixture()
          ..['processes'] = _source(
            entries: [
              {
                'pid': 42,
                'path': r'C:\Apps\browser.exe',
                'upload': 100,
                'download': 200,
              },
            ],
          ),
      );
      final counters = data.processes!;
      expect(counters.sampledAt, data.sampledAt);
      expect(counters.unattributedUpload, 7);
      expect(counters.unattributedDownload, 8);
      expect(counters.entries.single.pid, 42);
      expect(counters.entries.single.upload, 100);
      expect(() => counters.entries.clear(), throwsUnsupportedError);
    },
  );

  test(
    'malformed, repeated and oversized process identities cannot be ranked',
    () {
      for (final row in [
        {'pid': -1, 'path': 'app', 'upload': 0, 'download': 0},
        {'pid': 0x100000000, 'path': 'app', 'upload': 0, 'download': 0},
        {'pid': 0, 'path': '', 'upload': 0, 'download': 0},
        {'pid': 1, 'path': 'a\u0000b', 'upload': 0, 'download': 0},
        {'pid': 1, 'path': '文' * 400, 'upload': 0, 'download': 0},
        {'pid': 1, 'path': 'app', 'upload': -1, 'download': 0},
      ]) {
        expect(
          () => CoreProcessTraffic.fromJson(_source(entries: [row])),
          throwsFormatException,
        );
      }
      final row = {'pid': 1, 'path': 'app', 'upload': 1, 'download': 2};
      expect(
        () => CoreProcessTraffic.fromJson(_source(entries: [row, row])),
        throwsFormatException,
      );
      for (final patch in [
        {'capacity': 42},
        {'overflow': 'true'},
        {
          'unattributed': {'upload': -1, 'download': 0},
        },
        {'entries': List.filled(1025, row)},
      ]) {
        expect(
          () => CoreProcessTraffic.fromJson({..._source(), ...patch}),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'application grouping combines process counters but preserves distinct unknown paths',
    () async {
      final source = CoreProcessTraffic.fromJson(
        _source(
          entries: [
            {'pid': 1, 'path': 'browser.exe', 'upload': 100, 'download': 0},
            {'pid': 2, 'path': 'browser.exe', 'upload': 0, 'download': 200},
            {'pid': 3, 'path': 'editor.exe', 'upload': 10, 'download': 20},
            {'pid': 4, 'path': '', 'upload': 0, 'download': 40},
            {'pid': 5, 'path': '', 'upload': 0, 'download': 50},
          ],
          overflow: true,
        ),
      );
      final apps = await rankProcessTraffic(
        source,
        ProcessTrafficGrouping.application,
      );
      expect(apps.map((entry) => entry.total), [300, 50, 40, 30]);
      expect(apps.first.pids, [1, 2]);
      expect(apps.first.upload, 100);
      expect(apps.first.download, 200);
      expect(() => apps.first.pids.clear(), throwsUnsupportedError);
      expect(() => apps.clear(), throwsUnsupportedError);
      final processes = await rankProcessTraffic(
        source,
        ProcessTrafficGrouping.process,
      );
      expect(processes.map((entry) => entry.total), [200, 100, 50, 40, 30]);
      expect(source.unattributedUpload, 7);
      expect(source.overflow, isTrue);
    },
  );

  test(
    'same-byte ranks are stable and a fresh engine snapshot replaces old totals',
    () async {
      final old = CoreProcessTraffic.fromJson(
        _source(
          entries: [
            {'pid': 5, 'path': 'z', 'upload': 10, 'download': 0},
            {'pid': 2, 'path': 'a', 'upload': 0, 'download': 10},
          ],
        ),
      );
      expect(
        (await rankProcessTraffic(
          old,
          ProcessTrafficGrouping.process,
        )).map((entry) => entry.path),
        ['a', 'z'],
      );
      expect(
        await rankProcessTraffic(
          CoreProcessTraffic.fromJson(_source()),
          ProcessTrafficGrouping.application,
        ),
        isEmpty,
      );
    },
  );
}
