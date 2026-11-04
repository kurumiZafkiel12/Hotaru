enum CoreNodeProtocol { direct, http, socks }

final class CoreNodeSpec {
  final String tag;
  final CoreNodeProtocol protocol;
  final String? server;
  final int? port;
  final String? username;
  final String? password;

  const CoreNodeSpec({
    required this.tag,
    required this.protocol,
    this.server,
    this.port,
    this.username,
    this.password,
  });
}

final class CoreSelectorSpec {
  final String tag;
  final List<String> members;
  final String? selected;

  CoreSelectorSpec({
    required this.tag,
    required List<String> members,
    this.selected,
  }) : members = List.unmodifiable(members);
}

final class CoreProfileSpec {
  final List<CoreNodeSpec> nodes;
  final List<CoreSelectorSpec> selectors;
  final String finalOutbound;

  CoreProfileSpec({
    required List<CoreNodeSpec> nodes,
    required List<CoreSelectorSpec> selectors,
    required this.finalOutbound,
  }) : nodes = List.unmodifiable(nodes),
       selectors = List.unmodifiable(selectors);
}

final class CoreListenerSpec {
  final int mixedPort;
  final int controllerPort;
  final String secret;

  const CoreListenerSpec({
    required this.mixedPort,
    required this.controllerPort,
    required this.secret,
  });
}

final class CoreConfigIssue {
  final String code;
  final String path;

  const CoreConfigIssue(this.code, this.path);
}

final class CoreConfigBuildResult {
  final String? json;
  final List<CoreConfigIssue> issues;

  CoreConfigBuildResult({this.json, required List<CoreConfigIssue> issues})
    : issues = List.unmodifiable(issues);
}
