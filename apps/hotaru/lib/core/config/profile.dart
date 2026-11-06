import 'dns.dart';

enum CoreNodeProtocol {
  direct,
  http,
  socks,
  shadowsocks,
  vmess,
  vless,
  trojan,
  hysteria2,
  tuic,
}

final class CoreTlsSpec {
  final String? serverName;
  final bool insecure;
  final List<String> alpn;
  final String? fingerprint;
  final String? realityPublicKey;
  final String? realityShortId;

  CoreTlsSpec({
    this.serverName,
    this.insecure = false,
    List<String> alpn = const [],
    this.fingerprint,
    this.realityPublicKey,
    this.realityShortId,
  }) : alpn = List.unmodifiable(alpn);
}

enum CoreTransportKind { ws, grpc }

final class CoreTransportSpec {
  final CoreTransportKind kind;
  final String? path;
  final Map<String, String> headers;
  final String? serviceName;

  CoreTransportSpec({
    required this.kind,
    this.path,
    Map<String, String> headers = const {},
    this.serviceName,
  }) : headers = Map.unmodifiable(headers);
}

final class CoreNodeSpec {
  final String tag;
  final CoreNodeProtocol protocol;
  final String? server;
  final int? port;
  final String? detour;
  final String? username;
  final String? password;
  final String? uuid;
  final String? cipher;
  final int? alterId;
  final String? flow;
  final CoreTlsSpec? tls;
  final CoreTransportSpec? transport;
  final String? congestionControl;
  final String? udpRelayMode;
  final String? obfsPassword;
  final int? upMbps;
  final int? downMbps;
  final bool tcpOnly;

  const CoreNodeSpec({
    required this.tag,
    required this.protocol,
    this.server,
    this.port,
    this.detour,
    this.username,
    this.password,
    this.uuid,
    this.cipher,
    this.alterId,
    this.flow,
    this.tls,
    this.transport,
    this.congestionControl,
    this.udpRelayMode,
    this.obfsPassword,
    this.upMbps,
    this.downMbps,
    this.tcpOnly = false,
  });
}

enum CoreGroupStrategy { selector, urltest }

final class CoreSelectorSpec {
  final String tag;
  final List<String> members;
  final String? selected;
  final CoreGroupStrategy strategy;
  final String testUrl;
  final Duration interval;
  final int tolerance;

  CoreSelectorSpec({
    required this.tag,
    required List<String> members,
    this.selected,
    this.strategy = CoreGroupStrategy.selector,
    this.testUrl = 'https://www.gstatic.com/generate_204',
    this.interval = const Duration(minutes: 5),
    this.tolerance = 50,
  }) : members = List.unmodifiable(members);
}

enum CoreRuleKind { domain, domainSuffix, domainKeyword, ipCidr, always }

enum CoreRuleAction { route, reject, drop }

final class CoreRouteRule {
  final CoreRuleKind kind;
  final String value;
  final String? outbound;
  final CoreRuleAction action;
  final bool noResolve;

  const CoreRouteRule({
    required this.kind,
    required this.value,
    this.outbound,
    this.action = CoreRuleAction.route,
    this.noResolve = false,
  });
}

final class CoreProfileSpec {
  final List<CoreNodeSpec> nodes;
  final List<CoreSelectorSpec> selectors;
  final String finalOutbound;
  final List<CoreRouteRule> rules;
  final CoreDnsSpec? dns;

  CoreProfileSpec({
    required List<CoreNodeSpec> nodes,
    required List<CoreSelectorSpec> selectors,
    required this.finalOutbound,
    List<CoreRouteRule> rules = const [],
    this.dns,
  }) : nodes = List.unmodifiable(nodes),
       selectors = List.unmodifiable(selectors),
       rules = List.unmodifiable(rules);
}

final class CoreTunSpec {
  final String interfaceName;
  final List<String> addresses;
  final bool autoRoute;
  final bool hijackDns;

  CoreTunSpec({
    required this.interfaceName,
    required List<String> addresses,
    required this.autoRoute,
    this.hijackDns = false,
  }) : addresses = List.unmodifiable(addresses);
}

final class CoreListenerSpec {
  final int mixedPort;
  final int controllerPort;
  final String secret;
  final CoreTunSpec? tun;
  final int? dnsPort;

  const CoreListenerSpec({
    required this.mixedPort,
    required this.controllerPort,
    required this.secret,
    this.tun,
    this.dnsPort,
  });
}

enum CoreConfigIssueSeverity { error, warning }

final class CoreConfigIssue {
  final String code;
  final String path;
  final CoreConfigIssueSeverity severity;

  const CoreConfigIssue(
    this.code,
    this.path, {
    this.severity = CoreConfigIssueSeverity.error,
  });
}

final class CoreConfigImportResult {
  final CoreProfileSpec? profile;
  final List<CoreConfigIssue> issues;

  CoreConfigImportResult({this.profile, required List<CoreConfigIssue> issues})
    : issues = List.unmodifiable(issues);
}

final class CoreConfigBuildResult {
  final String? json;
  final List<CoreConfigIssue> issues;

  CoreConfigBuildResult({this.json, required List<CoreConfigIssue> issues})
    : issues = List.unmodifiable(issues);
}
