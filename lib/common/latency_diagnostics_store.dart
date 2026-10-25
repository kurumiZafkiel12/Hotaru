import 'dart:convert';
import 'dart:io';

import 'package:hotaru/common/common.dart';
import 'package:path/path.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LatencyDiagnosticsStore {
  LatencyDiagnosticsStore._();

  static final instance = LatencyDiagnosticsStore._();

  bool _enabled = false;
  Future<void>? _loadFuture;
  Future<void> _writeChain = Future.value();

  bool get enabled => _enabled;

  Future<void> ensureLoaded() {
    return _loadFuture ??= _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(latencyDiagnosticsPrefsKey) ?? false;
    } catch (_) {
      _enabled = false;
    }
  }

  Future<void> setEnabled(bool value) async {
    _enabled = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(latencyDiagnosticsPrefsKey, value);
    } catch (_) {
      // A toggle that cannot persist still applies to this session.
    }
  }

  Future<String> get logFilePath async {
    return join(await appPath.homeDirPath, latencyDiagnosticsLogFileName);
  }

  Future<void> record(Map<String, Object?> entry) {
    _writeChain = _writeChain.then((_) => _append(entry));
    return _writeChain;
  }

  Future<void> recordConfigSnapshot(Map<String, Object?> summary) {
    return record({
      'type': 'config',
      'time': DateTime.now().toUtc().toIso8601String(),
      ...summary,
    });
  }

  Future<void> _append(Map<String, Object?> entry) async {
    try {
      final path = await logFilePath;
      final file = File(path);
      var lines = <String>[];
      if (await file.exists()) {
        lines = await file.readAsLines();
        if (await file.length() > latencyDiagnosticsMaxLogBytes &&
            lines.length > latencyDiagnosticsMaxKeptLines) {
          lines = lines.sublist(lines.length - latencyDiagnosticsMaxKeptLines);
        }
      }
      lines.add(json.encode(entry));
      await file.writeAsString('${lines.join('\n')}\n');
    } catch (_) {
      // Diagnostic logging must never break delay tests.
    }
  }

  Future<List<Map<String, Object?>>> readRecords({int limit = 500}) async {
    try {
      final file = File(await logFilePath);
      if (!await file.exists()) {
        return [];
      }
      final records = <Map<String, Object?>>[];
      for (final line in await file.readAsLines()) {
        final decoded = json.decode(line);
        if (decoded is Map<String, Object?>) {
          records.add(decoded);
        }
      }
      return records.reversed.take(limit).toList();
    } catch (_) {
      return [];
    }
  }
}

final latencyDiagnosticsStore = LatencyDiagnosticsStore.instance;
