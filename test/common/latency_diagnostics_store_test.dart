import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/common/latency_diagnostics.dart';
import 'package:hotaru/common/latency_diagnostics_store.dart';
import 'package:path/path.dart' as p;

import '../helpers/app_paths.dart';
import '../helpers/preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late LatencyDiagnosticsStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('hotaru-diagnostics-');
    await useAppPaths(root);
    await mockPreferences();
    store = LatencyDiagnosticsStore.forTesting();
  });

  tearDown(() async {
    expect(
      p.isWithin(Directory.systemTemp.absolute.path, root.absolute.path),
      isTrue,
    );
    expect(p.basename(root.path), startsWith('hotaru-diagnostics-'));
    await root.delete(recursive: true);
  });

  test('disabled diagnostics do not create a log', () async {
    await store.record({'index': 1});
    expect(await File(await store.logFilePath).exists(), isFalse);
  });

  test(
    'concurrent records keep their order and reads return the latest',
    () async {
      await store.setEnabled(true);
      await Future.wait(List.generate(60, (i) => store.record({'index': i})));
      final records = await store.readRecords(limit: 3);
      expect(records.map((r) => r['index']), [59, 58, 57]);
    },
  );

  test('rotation bounds both files and retains recent records', () async {
    await store.setEnabled(true);
    final payload = 'a' * (latencyDiagnosticsMaxLogBytes ~/ 2 - 128);
    for (var i = 0; i < 3; i++) {
      await store.record({'index': i, 'payload': payload});
    }
    final path = await store.logFilePath;
    expect(
      await File(path).length(),
      lessThanOrEqualTo(latencyDiagnosticsMaxLogBytes),
    );
    expect(
      await File('$path.previous').length(),
      lessThanOrEqualTo(latencyDiagnosticsMaxLogBytes),
    );
    expect((await store.readRecords(limit: 2)).map((r) => r['index']), [2, 1]);
  });

  test('a malformed line does not hide surrounding valid records', () async {
    await File(await store.logFilePath).writeAsString(
      '${jsonEncode({'index': 1})}\ninvalid\n${jsonEncode({'index': 2})}\n',
    );
    expect((await store.readRecords()).map((r) => r['index']), [2, 1]);
  });

  test('an oversized legacy log is bounded on the next write', () async {
    final file = File(await store.logFilePath);
    await file.writeAsString('x' * (latencyDiagnosticsMaxLogBytes + 100));
    await store.setEnabled(true);
    await store.record({'index': 3});
    expect(
      await file.length(),
      lessThanOrEqualTo(latencyDiagnosticsMaxLogBytes),
    );
    expect((await store.readRecords()).single['index'], 3);
  });
}
