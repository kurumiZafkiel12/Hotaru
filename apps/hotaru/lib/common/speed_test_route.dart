const speedTestGroupBaseName = 'HOTARU-SPEEDTEST';
const speedTestListenerName = 'hotaru-speedtest';
const speedTestPort = 17890;
const speedTestProxy = 'PROXY 127.0.0.1:$speedTestPort';

bool isSpeedTestGroupName(String name) {
  return name == speedTestGroupBaseName ||
      name.startsWith('$speedTestGroupBaseName-');
}

String? findSpeedTestGroupName(Map<String, dynamic> proxies) {
  for (final name in proxies.keys) {
    if (isSpeedTestGroupName(name)) {
      return name;
    }
  }
  return null;
}

/// Walks group selections (`now`) from [target] down to the leaf outbound.
List<String> resolveProxyChain(Map<String, dynamic> proxies, String target) {
  final chain = <String>[target];
  final visited = <String>{target};
  var current = target;
  while (true) {
    final raw = proxies[current];
    if (raw is! Map) {
      break;
    }
    final now = raw['now'];
    if (now is! String || now.isEmpty || !visited.add(now)) {
      break;
    }
    chain.add(now);
    current = now;
  }
  return chain;
}

/// Adds a loopback listener whose traffic the core forces through a
/// reserved select group, binding a per-node bandwidth test to its target
/// without touching user selections or rules. Returns '' if untestable.
String injectSpeedTestRoute(Map<dynamic, dynamic> rawConfig) {
  final proxyDefs = rawConfig['proxies'];
  final proxyNames = <String>[
    if (proxyDefs is List)
      for (final def in proxyDefs)
        if (def is Map && def['name'] is String) def['name'] as String,
  ];
  final groupDefs = rawConfig['proxy-groups'];
  final groups = <Map<String, dynamic>>[
    if (groupDefs is List)
      for (final def in groupDefs)
        if (def is Map) Map<String, dynamic>.from(def),
  ];
  final providerNames = <String>{
    for (final group in groups)
      if (group['use'] is List)
        for (final use in group['use'] as List)
          if (use is String) use,
  };
  if (proxyNames.isEmpty && providerNames.isEmpty) {
    return '';
  }
  final groupNames = <String>[
    for (final group in groups)
      if (group['name'] is String) group['name'] as String,
  ];
  final taken = {...proxyNames, ...groupNames};
  var name = speedTestGroupBaseName;
  var suffix = 2;
  while (taken.contains(name)) {
    name = '$speedTestGroupBaseName-${suffix++}';
  }
  final members = <String>[];
  final seen = <String>{};
  for (final member in [...proxyNames, ...groupNames, 'DIRECT']) {
    if (member != name && seen.add(member)) {
      members.add(member);
    }
  }
  groups.add({
    'name': name,
    'type': 'select',
    'proxies': members,
    if (providerNames.isNotEmpty) 'use': providerNames.toList(),
  });
  rawConfig['proxy-groups'] = groups;
  final listeners = rawConfig['listeners'];
  rawConfig['listeners'] = [
    if (listeners is List) ...listeners,
    {
      'name': speedTestListenerName,
      'type': 'mixed',
      'listen': '127.0.0.1',
      'port': speedTestPort,
      'proxy': name,
    },
  ];
  return name;
}

/// Serializes per-node tests: the reserved group has a single selection,
/// so concurrent tests would measure each other's target.
class NodeSpeedTestGate {
  NodeSpeedTestGate._();

  static int _nextToken = 1;
  static int? _activeToken;

  static int? tryAcquire() {
    if (_activeToken != null) {
      return null;
    }
    final token = _nextToken++;
    _activeToken = token;
    return token;
  }

  static bool isActive(int token) => _activeToken == token;

  static void release(int token) {
    if (_activeToken == token) {
      _activeToken = null;
    }
  }
}
