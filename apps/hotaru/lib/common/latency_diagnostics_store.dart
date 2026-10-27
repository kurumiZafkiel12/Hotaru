import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:hotaru/common/common.dart';
import 'package:path/path.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LatencyDiagnosticsStore {
  LatencyDiagnosticsStore._();

  @visibleForTesting
  LatencyDiagnosticsStore.forTesting();

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
    if (!_enabled) return Future.value();
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
    if (!_enabled) return;
    try {
      final path = await logFilePath;
      final file = File(path);
      final line = '${json.encode(entry)}\n';
      final bytes = utf8.encode(line);
      if (bytes.length > latencyDiagnosticsMaxLogBytes) return;
      if (await file.exists()) {
        final size = await file.length();
        if (size > latencyDiagnosticsMaxLogBytes) {
          await file.writeAsString('');
        } else if (size + bytes.length > latencyDiagnosticsMaxLogBytes) {
          final previous = File('$path.previous');
          if (await previous.exists()) await previous.delete();
          await file.rename(previous.path);
        }
      }
      await file.writeAsBytes(bytes, mode: FileMode.append);
    } catch (_) {
      // Diagnostic logging must never break delay tests.
    }
  }

  Future<List<Map<String, Object?>>> readRecords({int limit = 500}) async {
    try {
      await _writeChain;
      final path = await logFilePath;
      return await Isolate.run(() => _readDiagnosticTail(path, limit));
    } catch (_) {
      return [];
    }
  }
}

List<Map<String, Object?>> _readDiagnosticTail(String path, int limit) {
  final records = <Map<String, Object?>>[];
  for (final candidate in [path, '$path.previous']) {
    if (records.length >= limit) break;
    final file = File(candidate);
    if (!file.existsSync()) continue;
    final handle = file.openSync();
    try {
      final length = handle.lengthSync();
      final start = (length - latencyDiagnosticsMaxLogBytes).clamp(0, length);
      handle.setPositionSync(start);
      final bytes = handle.readSync(length - start);
      var text = utf8.decode(bytes, allowMalformed: true);
      if (start > 0) {
        final newline = text.indexOf('\n');
        text = newline < 0 ? '' : text.substring(newline + 1);
      }
      for (final line in text.split('\n').reversed) {
        if (records.length >= limit) break;
        try {
          final decoded = json.decode(line);
          if (decoded is Map<String, Object?>) records.add(decoded);
        } on FormatException {
          continue;
        }
      }
    } finally {
      handle.closeSync();
    }
  }
  return records;
}

final latencyDiagnosticsStore = LatencyDiagnosticsStore.instance;
