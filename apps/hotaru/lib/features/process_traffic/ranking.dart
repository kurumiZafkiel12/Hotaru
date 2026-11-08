import 'dart:isolate';

import '../../core/telemetry.dart';

enum ProcessTrafficGrouping { application, process }

final class ProcessTrafficRow {
  final String path;
  final List<int> pids;
  final int upload;
  final int download;

  ProcessTrafficRow({
    required this.path,
    required List<int> pids,
    required this.upload,
    required this.download,
  }) : pids = List.unmodifiable(pids);

  int get total => upload + download;
}

Future<List<ProcessTrafficRow>> rankProcessTraffic(
  CoreProcessTraffic source,
  ProcessTrafficGrouping grouping,
) => Isolate.run(() {
  final groups = <(int, String), List<CoreProcessCounter>>{};
  for (final entry in source.entries) {
    final key = (
      grouping == ProcessTrafficGrouping.application && entry.path.isNotEmpty
          ? 0
          : entry.pid,
      entry.path,
    );
    groups.putIfAbsent(key, () => []).add(entry);
  }
  final result = <ProcessTrafficRow>[];
  for (final group in groups.values) {
    final pids =
        group.map((entry) => entry.pid).where((pid) => pid > 0).toSet().toList()
          ..sort();
    result.add(
      ProcessTrafficRow(
        path: group.first.path,
        pids: pids,
        upload: group.fold(0, (total, entry) => total + entry.upload),
        download: group.fold(0, (total, entry) => total + entry.download),
      ),
    );
  }
  result.sort((a, b) {
    final total = b.total.compareTo(a.total);
    if (total != 0) return total;
    final path = a.path.compareTo(b.path);
    if (path != 0) return path;
    return (a.pids.firstOrNull ?? 0).compareTo(b.pids.firstOrNull ?? 0);
  });
  return List<ProcessTrafficRow>.unmodifiable(result);
});
