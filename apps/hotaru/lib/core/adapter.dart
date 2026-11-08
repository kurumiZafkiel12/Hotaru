abstract interface class CoreAdapter {
  Future<List<CoreOutbound>> outbounds();

  Future<void> selectOutbound(String group, String outbound);

  Future<Duration> delay(String outbound, Uri target, Duration timeout);

  Future<CoreConnections> connections();

  Future<void> closeConnection(String id);

  Future<void> close();
}

final class CoreOutbound {
  final String name;
  final String type;
  final List<String> members;
  final String? selected;

  const CoreOutbound({
    required this.name,
    required this.type,
    required this.members,
    this.selected,
  });
}

final class CoreConnections {
  final int uploadTotal;
  final int downloadTotal;
  final List<CoreConnection> entries;

  const CoreConnections({
    required this.uploadTotal,
    required this.downloadTotal,
    required this.entries,
  });
}

final class CoreConnection {
  final String id;
  final String inbound;
  final String network;
  final String host;
  final String destinationIp;
  final String destinationPort;
  final String? processPath;
  final List<String> chain;
  final String rule;
  final int upload;
  final int download;

  const CoreConnection({
    required this.id,
    required this.inbound,
    required this.network,
    required this.host,
    required this.destinationIp,
    required this.destinationPort,
    required this.processPath,
    required this.chain,
    required this.rule,
    required this.upload,
    required this.download,
  });
}

final class CoreAdapterException implements Exception {
  final String code;
  final int? status;

  const CoreAdapterException(this.code, {this.status});

  @override
  String toString() => 'CoreAdapterException($code, status: $status)';
}
