abstract interface class CoreFinalTrafficSource {
  int? get profileId;
  Future<CoreTrafficTotals?> get finalTraffic;
}

final class CoreTrafficTotals {
  final int upload;
  final int download;

  const CoreTrafficTotals({required this.upload, required this.download});

  factory CoreTrafficTotals.fromJson(Map<String, dynamic> value) =>
      CoreTrafficTotals(
        upload: _integer(value, 'upload'),
        download: _integer(value, 'download'),
      );
}

abstract interface class CoreTelemetry {
  Future<CoreTelemetrySnapshot> telemetry();
}

final class CoreTelemetrySnapshot {
  final DateTime sampledAt;
  final int uploadTotal;
  final int downloadTotal;
  final int historyCapacity;
  final bool activeTruncated;
  final List<CoreObservedConnection> active;
  final List<CoreObservedConnection> closed;
  final CoreObservedMemory? memory;

  CoreTelemetrySnapshot({
    required this.sampledAt,
    required this.uploadTotal,
    required this.downloadTotal,
    required this.historyCapacity,
    required this.activeTruncated,
    required List<CoreObservedConnection> active,
    required List<CoreObservedConnection> closed,
    this.memory,
  }) : active = List.unmodifiable(active),
       closed = List.unmodifiable(closed);

  factory CoreTelemetrySnapshot.fromJson(Map<String, dynamic> value) {
    List<CoreObservedConnection> entries(String key, {required bool closed}) {
      final list = value[key];
      if (list is! List || list.length > 1000) {
        throw const FormatException('Invalid telemetry entries');
      }
      return list.map((item) {
        if (item is! Map<String, dynamic>) {
          throw const FormatException('Invalid telemetry entry');
        }
        final entry = CoreObservedConnection.fromJson(item);
        if (closed != (entry.closedAt != null)) {
          throw const FormatException('Invalid connection lifetime');
        }
        return entry;
      }).toList();
    }

    final capacity = _integer(value, 'history_capacity');
    final truncated = value['active_truncated'];
    if (capacity != 1000 || truncated is! bool) {
      throw const FormatException('Invalid telemetry limits');
    }
    return CoreTelemetrySnapshot(
      sampledAt: _date(value, 'sampled_at'),
      uploadTotal: _integer(value, 'upload_total'),
      downloadTotal: _integer(value, 'download_total'),
      historyCapacity: capacity,
      activeTruncated: truncated,
      active: entries('active', closed: false),
      closed: entries('closed', closed: true),
      memory: switch (value['memory']) {
        null => null,
        final Map<String, dynamic> memory => CoreObservedMemory.fromJson(
          memory,
        ),
        _ => throw const FormatException('Invalid memory observation'),
      },
    );
  }
}

final class CoreObservedMemory {
  final int rss;
  final int heapInuse;
  final int heapIdle;
  final int stackInuse;
  final int runtimeOther;

  const CoreObservedMemory({
    required this.rss,
    required this.heapInuse,
    required this.heapIdle,
    required this.stackInuse,
    required this.runtimeOther,
  });

  factory CoreObservedMemory.fromJson(Map<String, dynamic> value) =>
      CoreObservedMemory(
        rss: _integer(value, 'rss'),
        heapInuse: _integer(value, 'heap_inuse'),
        heapIdle: _integer(value, 'heap_idle'),
        stackInuse: _integer(value, 'stack_inuse'),
        runtimeOther: _integer(value, 'runtime_other'),
      );
}

final class CoreObservedConnection {
  final String id;
  final DateTime createdAt;
  final DateTime? closedAt;
  final int upload;
  final int download;
  final String inbound;
  final String network;
  final String sourceIp;
  final int sourcePort;
  final String destinationIp;
  final int destinationPort;
  final String host;
  final int processId;
  final String processPath;
  final List<String> chain;
  final String rule;
  final String outbound;
  final String outboundType;

  CoreObservedConnection({
    required this.id,
    required this.createdAt,
    this.closedAt,
    required this.upload,
    required this.download,
    required this.inbound,
    required this.network,
    required this.sourceIp,
    required this.sourcePort,
    required this.destinationIp,
    required this.destinationPort,
    required this.host,
    required this.processId,
    required this.processPath,
    required List<String> chain,
    required this.rule,
    required this.outbound,
    required this.outboundType,
  }) : chain = List.unmodifiable(chain);

  factory CoreObservedConnection.fromJson(Map<String, dynamic> value) {
    final rawChain = value['chain'];
    if (rawChain is! List || rawChain.any((tag) => tag is! String)) {
      throw const FormatException('Invalid connection chain');
    }
    final sourcePort = _integer(value, 'source_port');
    final destinationPort = _integer(value, 'destination_port');
    final processId = _integer(value, 'process_id');
    final createdAt = _date(value, 'created_at');
    final closedAt = value.containsKey('closed_at')
        ? _date(value, 'closed_at')
        : null;
    if (sourcePort > 65535 ||
        destinationPort > 65535 ||
        processId > 0xffffffff) {
      throw const FormatException('Invalid connection metadata');
    }
    return CoreObservedConnection(
      id: _string(value, 'id'),
      createdAt: createdAt,
      closedAt: closedAt,
      upload: _integer(value, 'upload'),
      download: _integer(value, 'download'),
      inbound: _string(value, 'inbound'),
      network: _string(value, 'network'),
      sourceIp: _string(value, 'source_ip'),
      sourcePort: sourcePort,
      destinationIp: _string(value, 'destination_ip'),
      destinationPort: destinationPort,
      host: _string(value, 'host'),
      processId: processId,
      processPath: _string(value, 'process_path'),
      chain: rawChain.cast<String>(),
      rule: _string(value, 'rule'),
      outbound: _string(value, 'outbound'),
      outboundType: _string(value, 'outbound_type'),
    );
  }
}

int _integer(Map<String, dynamic> value, String key) {
  final field = value[key];
  if (field is! int || field < 0) {
    throw const FormatException('Invalid telemetry counter');
  }
  return field;
}

String _string(Map<String, dynamic> value, String key) {
  final field = value[key];
  if (field is! String) throw const FormatException('Invalid telemetry text');
  return field;
}

DateTime _date(Map<String, dynamic> value, String key) {
  final result = DateTime.tryParse(_string(value, key));
  if (result == null || !result.isUtc) {
    throw const FormatException('Invalid telemetry time');
  }
  return result;
}
