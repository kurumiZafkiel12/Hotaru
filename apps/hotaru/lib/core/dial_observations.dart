import 'dart:convert';

final class CoreDialObservations {
  final List<CoreDialObservation> entries;

  CoreDialObservations._(this.entries);

  factory CoreDialObservations.fromJson(Map<String, dynamic> value) {
    final raw = value['entries'];
    final first = value['first_id'];
    final last = value['last_id'];
    if (value['capacity'] != 4096 ||
        raw is! List ||
        raw.length > 4096 ||
        first is! int ||
        last is! int ||
        (raw.isEmpty
            ? first != 0 || last != 0
            : first < 1 || last - first + 1 != raw.length)) {
      throw const FormatException('Invalid dial observation window');
    }
    final entries = <CoreDialObservation>[];
    for (final item in raw) {
      if (item is! Map<String, dynamic> ||
          item['id'] != first + entries.length) {
        throw const FormatException('Invalid dial observation order');
      }
      entries.add(CoreDialObservation.fromJson(item));
    }
    return CoreDialObservations._(List.unmodifiable(entries));
  }
}

final class CoreDialObservation {
  final int id;
  final int rootId;
  final String parent;
  final String outbound;
  final String outboundType;
  final String destination;
  final bool dns;
  final bool succeeded;
  final String inbound;
  final String network;
  final String sourceIp;
  final int sourcePort;
  final String originalDestination;
  final int destinationPort;
  final String host;
  final DateTime startedAt;
  final DateTime? completedAt;

  CoreDialObservation.fromJson(Map<String, dynamic> value)
    : id = _number(value, 'id'),
      rootId = _number(value, 'root_id'),
      parent = _text(value, 'parent'),
      outbound = _text(value, 'outbound'),
      outboundType = _text(value, 'outbound_type'),
      destination = _text(value, 'dial_destination'),
      dns = _boolean(value, 'dns'),
      succeeded = _boolean(value, 'succeeded'),
      inbound = _text(_origin(value), 'inbound'),
      network = _text(_origin(value), 'network'),
      sourceIp = _text(_origin(value), 'source_ip'),
      sourcePort = _number(_origin(value), 'source_port', port: true),
      originalDestination = _text(_origin(value), 'destination'),
      destinationPort = _number(_origin(value), 'destination_port', port: true),
      host = _text(_origin(value), 'host'),
      startedAt = _date(value, 'started_at'),
      completedAt = value['completed_at'] == null
          ? null
          : _date(value, 'completed_at') {
    if (id < 1 ||
        rootId < 1 ||
        rootId > id ||
        completedAt != null && completedAt!.isBefore(startedAt)) {
      throw const FormatException('Invalid dial lifetime');
    }
  }
}

Map<String, dynamic> _origin(Map<String, dynamic> value) =>
    switch (value['origin']) {
      final Map<String, dynamic> origin => origin,
      _ => throw const FormatException('Invalid dial origin'),
    };
String _text(Map<String, dynamic> value, String key) {
  final text = value[key];
  if (text is! String ||
      text.contains('\u0000') ||
      utf8.encode(text).length > 1024) {
    throw const FormatException('Invalid dial field');
  }
  return text;
}

int _number(Map<String, dynamic> value, String key, {bool port = false}) {
  final number = value[key];
  if (number is! int ||
      number < 0 ||
      number > (port ? 65535 : 9007199254740991)) {
    throw const FormatException('Invalid dial identifier');
  }
  return number;
}

bool _boolean(Map<String, dynamic> value, String key) => switch (value[key]) {
  final bool result => result,
  _ => throw const FormatException('Invalid dial flag'),
};
DateTime _date(Map<String, dynamic> value, String key) {
  final raw = value[key];
  final parsed = raw is String ? DateTime.tryParse(raw) : null;
  if (parsed == null || !parsed.isUtc) {
    throw const FormatException('Invalid dial timestamp');
  }
  return parsed;
}
