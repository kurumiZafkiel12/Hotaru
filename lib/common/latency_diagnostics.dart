import 'dart:convert';

import 'package:crypto/crypto.dart';

const latencyDiagnosticsPrefsKey = 'latencyDiagnosticsEnabled';
const latencyDiagnosticsLogFileName = 'latency_diagnostics.jsonl';
const latencyDiagnosticsMaxLogBytes = 2000000;
const latencyDiagnosticsMaxKeptLines = 1000;

const latencyErrorTimeout = 'timeout';
const latencyErrorDns = 'dns';
const latencyErrorTls = 'tls';
const latencyErrorUdpQuic = 'udp-quic';
const latencyErrorParameterDifference = 'parameter-difference';
const latencyErrorUnknown = 'unknown';

const latencySplitUnavailableReason =
    'The delay wrapper returns only a final value, so the first and second '
    'request outcomes inside the core URLTest cannot be observed from Dart. '
    'Observing them needs a hook inside the pinned core, which this build '
    'does not patch.';

Map<String, Object?> latencySplitUnavailable() => {
  'first': 'unavailable',
  'secondAttempted': 'unavailable',
  'second': 'unavailable',
  'startUsed': 'unavailable',
  'reason': latencySplitUnavailableReason,
};

String latencyNodeId(String proxyName) {
  final digest = sha256.convert(utf8.encode(proxyName));
  return digest.toString().substring(0, 12);
}

String latencySafeTarget(String rawUrl) {
  final uri = Uri.tryParse(rawUrl.trim());
  if (uri == null || uri.host.isEmpty) {
    return 'unparsable';
  }
  final path = uri.path.isEmpty ? '/' : uri.path;
  return '${uri.scheme}://${uri.host}$path';
}

String latencyErrorCategory({
  required int? coreDelay,
  required Object? error,
  required bool proxyKnown,
}) {
  if (coreDelay == -1) {
    return latencyErrorTimeout;
  }
  if (error != null) {
    final text = error.toString().toLowerCase();
    if (text.contains('timed out') ||
        text.contains('timeout') ||
        text.contains('deadline')) {
      return latencyErrorTimeout;
    }
    if (text.contains('certificate') ||
        text.contains('tls') ||
        text.contains('ssl') ||
        text.contains('handshake')) {
      return latencyErrorTls;
    }
    if (text.contains('quic') || text.contains('udp')) {
      return latencyErrorUdpQuic;
    }
    if (text.contains('dns') ||
        text.contains('resolve') ||
        text.contains('no such host') ||
        text.contains('nxdomain') ||
        text.contains('lookup')) {
      return latencyErrorDns;
    }
  }
  if (coreDelay == -2 && !proxyKnown) {
    return latencyErrorParameterDifference;
  }
  return latencyErrorUnknown;
}

String latencyDesensitize(String raw) {
  var text = raw;
  text = text.replaceAllMapped(RegExp(r'://[^/\s@]+@'), (match) => '://');
  text = text.replaceAll(RegExp(r'[?#][^\s]*'), '');
  text = text.replaceAllMapped(
    RegExp(
      r'\b(password|passwd|token|secret|uuid|api[-_]?key)\b\s*[:=]\s*\S+',
      caseSensitive: false,
    ),
    (match) => '${match.group(1)}=[REDACTED]',
  );
  text = text.replaceAllMapped(
    RegExp(r'\b(?:\d{1,3}\.){3}\d{1,3}\b'),
    (match) => '[IP]',
  );
  text = text.replaceAllMapped(
    RegExp(r'\b[0-9a-fA-F]*:[0-9a-fA-F:]*:[0-9a-fA-F:]+\b'),
    (match) => '[IP]',
  );
  text = text.replaceAllMapped(
    RegExp(
      r'\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b',
    ),
    (match) => '[UUID]',
  );
  text = text.replaceAllMapped(
    RegExp(r'\b[0-9a-fA-F]{20,}\b'),
    (match) => '[TOKEN]',
  );
  text = text.replaceAllMapped(
    RegExp(r'\b(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}\b'),
    (match) => '[HOST]',
  );
  if (text.length > 300) {
    text = text.substring(0, 300);
  }
  return text;
}

Map<String, Object?> latencyRoundRecord({
  required String roundId,
  required bool single,
  required String nodeId,
  required String protocol,
  required String testTarget,
  required String urlSource,
  required int queueMs,
  required int coreMs,
  required int? coreDelay,
  required int timeoutMs,
  required String status,
  required String category,
  String? errorText,
  String? note,
  bool? unifiedDelay,
  int? measuredMs,
}) {
  return {
    'type': 'round',
    'roundId': roundId,
    'time': DateTime.now().toUtc().toIso8601String(),
    'single': single,
    'node': nodeId,
    'protocol': protocol,
    'target': testTarget,
    'urlSource': urlSource,
    'queueMs': queueMs,
    'coreMs': coreMs,
    'coreDelay': coreDelay,
    'timeoutMs': timeoutMs,
    'status': status,
    'category': category,
    'effectiveUnifiedDelay': ?unifiedDelay,
    'measuredMs': ?measuredMs,
    if (errorText != null && errorText.isNotEmpty)
      'error': latencyDesensitize(errorText),
    if (note != null && note.isNotEmpty) 'note': note,
    'split': latencySplitUnavailable(),
  };
}
