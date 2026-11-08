final class CoreLocalCredential {
  final String username;
  final String password;

  const CoreLocalCredential(this.username, this.password);
}

final class CoreInboundOptions {
  final String listen;
  final List<CoreLocalCredential> users;
  final int? httpPort;
  final int? socksPort;

  CoreInboundOptions({
    this.listen = '127.0.0.1',
    List<CoreLocalCredential> users = const [],
    this.httpPort,
    this.socksPort,
  }) : users = List.unmodifiable(users);
}

final class CoreRuntimeOptions {
  final String? logLevel;
  final bool findProcess;
  final String? defaultInterface;
  final bool resolveIpv6;
  final int? tcpKeepAliveSeconds;
  final int? tcpKeepAliveIntervalSeconds;
  final bool disableTcpKeepAlive;
  final bool skipCertVerify;

  const CoreRuntimeOptions({
    this.logLevel,
    this.findProcess = false,
    this.defaultInterface,
    this.resolveIpv6 = true,
    this.tcpKeepAliveSeconds,
    this.tcpKeepAliveIntervalSeconds,
    this.disableTcpKeepAlive = false,
    this.skipCertVerify = false,
  });
}
