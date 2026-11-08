import 'dns.dart';
import 'probe_listener.dart';
import 'rule_set.dart';
import 'runtime_options.dart';
import '../routing_mode.dart';

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

enum CoreRuleKind {
  domain,
  domainSuffix,
  domainKeyword,
  ipCidr,
  ruleSet,
  always,
}

enum CoreRuleAction { route, global, reject, drop }

final class CoreRouteRule {
  final CoreRuleKind kind;
  final String value;
  final String? outbound;
  final CoreRuleAction action;
  final bool noResolve;
  final bool invert;

  const CoreRouteRule({
    required this.kind,
    required this.value,
    this.outbound,
    this.action = CoreRuleAction.route,
    this.noResolve = false,
    this.invert = false,
  });
}

final class CoreProfileSpec {
  final List<CoreNodeSpec> nodes;
  final List<CoreSelectorSpec> selectors;
  final String finalOutbound;
  final List<CoreRouteRule> rules;
  final List<CoreRuleSetSpec> ruleSets;
  final CoreDnsSpec? dns;
  final CoreRuntimeOptions runtime;

  CoreProfileSpec({
    required List<CoreNodeSpec> nodes,
    required List<CoreSelectorSpec> selectors,
    required this.finalOutbound,
    List<CoreRouteRule> rules = const [],
    List<CoreRuleSetSpec> ruleSets = const [],
    this.dns,
    this.runtime = const CoreRuntimeOptions(),
  }) : nodes = List.unmodifiable(nodes),
       selectors = List.unmodifiable(selectors),
       ruleSets = List.unmodifiable(ruleSets),
       rules = List.unmodifiable(rules);
}

final class CoreTunSpec {
  final String interfaceName;
  final List<String> addresses;
  final bool autoRoute;
  final bool hijackDns;
  final int? mtu;
  final List<String> routes;
  final List<String> excludedRoutes;

  CoreTunSpec({
    required this.interfaceName,
    required List<String> addresses,
    required this.autoRoute,
    this.hijackDns = false,
    this.mtu,
    List<String> routes = const [],
    List<String> excludedRoutes = const [],
  }) : addresses = List.unmodifiable(addresses),
       routes = List.unmodifiable(routes),
       excludedRoutes = List.unmodifiable(excludedRoutes);
}

final class CoreListenerSpec {
  final bool inboundsEnabled;
  final int mixedPort;
  final int controllerPort;
  final String secret;
  final CoreTunSpec? tun;
  final int? dnsPort;
  final CoreDnsGroupListeners? dnsGroups;
  final CoreProbeListenerSpec? probe;
  final CoreRoutingMode initialMode;
  final String? globalSelection;
  final CoreInboundOptions? inbound;

  const CoreListenerSpec({
    required this.mixedPort,
    required this.controllerPort,
    required this.secret,
    this.inboundsEnabled = true,
    this.tun,
    this.dnsPort,
    this.dnsGroups,
    this.probe,
    this.initialMode = CoreRoutingMode.rule,
    this.globalSelection,
    this.inbound,
  });

  List<int> get dataPorts => [
    mixedPort,
    ?inbound?.httpPort,
    ?inbound?.socksPort,
  ];

  CoreProbeListenerSpec? get activeProbe => inboundsEnabled ? probe : null;
  CoreTunSpec? get activeTun => inboundsEnabled ? tun : null;
  int? get activeDnsPort => inboundsEnabled ? dnsPort : null;

  CoreListenerSpec withInbounds(bool enabled) => CoreListenerSpec(
    mixedPort: mixedPort,
    controllerPort: controllerPort,
    secret: secret,
    inboundsEnabled: enabled,
    tun: tun,
    dnsPort: dnsPort,
    dnsGroups: dnsGroups,
    probe: probe,
    initialMode: initialMode,
    globalSelection: globalSelection,
    inbound: inbound,
  );

  CoreListenerSpec withRuntime({
    required bool enabled,
    required CoreRoutingMode mode,
    required String? globalSelection,
  }) => CoreListenerSpec(
    mixedPort: mixedPort,
    controllerPort: controllerPort,
    secret: secret,
    inboundsEnabled: enabled,
    tun: tun,
    dnsPort: dnsPort,
    dnsGroups: dnsGroups,
    probe: probe,
    initialMode: mode,
    globalSelection: globalSelection,
    inbound: inbound,
  );
}

enum CoreConfigIssueSeverity { error, warning }

final class CoreNodeImportResult {
  final CoreNodeSpec? node;
  final List<CoreConfigIssue> issues;

  CoreNodeImportResult(this.node, List<CoreConfigIssue> issues)
    : issues = List.unmodifiable(issues);
}

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
