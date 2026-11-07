enum CoreDnsProtocol { udp, tcp, tls, https, local }

final class CoreDnsServerSpec {
  final String tag;
  final CoreDnsProtocol protocol;
  final String? server;
  final int? port;
  final String? path;
  final String? detour;
  final String? addressResolver;

  const CoreDnsServerSpec({
    required this.tag,
    required this.protocol,
    this.server,
    this.port,
    this.path,
    this.detour,
    this.addressResolver,
  });
}

final class CoreDnsGroupSpec {
  final String tag;
  final List<String> members;

  CoreDnsGroupSpec({required this.tag, required List<String> members})
    : members = List.unmodifiable(members);
}

final class CoreDnsGroupListeners {
  final Map<String, int> ports;

  CoreDnsGroupListeners(Map<String, int> ports)
    : ports = Map.unmodifiable(ports);
}

final class CoreDnsSpec {
  final List<CoreDnsServerSpec> servers;
  final List<CoreDnsGroupSpec> groups;
  final String finalServer;
  final String? proxyServer;
  final bool ipv6;
  final int? cacheCapacity;

  CoreDnsSpec({
    required List<CoreDnsServerSpec> servers,
    List<CoreDnsGroupSpec> groups = const [],
    required this.finalServer,
    this.proxyServer,
    this.ipv6 = false,
    this.cacheCapacity,
  }) : servers = List.unmodifiable(servers),
       groups = List.unmodifiable(groups);
}
