import '../profiles/importer.dart';

/// Builds the runtime Mihomo config for the minimal proxy loop.
///
/// nodesOnly profiles get a generated structure:
///   HOTARU (select: [selected, 自动选择, ...all nodes, DIRECT])
///   自动选择 (url-test over all nodes, generate_204 probe)
///   rules: MATCH,HOTARU
/// fullConfig profiles keep their own proxies/groups/rules untouched; only
/// transport-level keys (ports, controller, TUN off) are set by the
/// controller at launch time.
class ProxyConfigBuilder {
  static const selectGroup = 'HOTARU';
  static const autoGroup = '自动选择';
  static const probeUrl = 'http://www.gstatic.com/generate_204';

  static Map<String, dynamic> build({
    required Map<String, dynamic> profileConfig,
    required ImportMode mode,
    required String selectedNode,
  }) {
    final proxies = profileConfig['proxies'];
    if (proxies is! List || proxies.isEmpty) {
      throw ArgumentError('Profile has no proxies');
    }
    final names = [
      for (final p in proxies)
        if (p is Map && p['name'] is String) p['name'] as String,
    ];
    if (!names.contains(selectedNode)) {
      throw ArgumentError('Selected node is not in the profile');
    }
    if (mode == ImportMode.fullConfig) {
      // Deep copy through JSON so the stored profile is never mutated.
      return _deepCopy(profileConfig);
    }
    return {
      'mode': 'rule',
      'log-level': 'info',
      'ipv6': false,
      // Deliberately no DNS `fallback`: Mihomo's fallback filter depends on
      // GeoIP data, whose first-run download can fail (offline, blocked)
      // and would make an otherwise valid config fail validation.
      'dns': {
        'enable': true,
        'ipv6': false,
        'enhanced-mode': 'fake-ip',
        'fake-ip-range': '198.18.0.1/16',
        'nameserver': ['223.5.5.5', '8.8.8.8'],
      },
      'proxies': _deepCopy(proxies),
      'proxy-groups': [
        {
          'name': selectGroup,
          'type': 'select',
          'proxies': [
            selectedNode,
            autoGroup,
            for (final n in names)
              if (n != selectedNode) n,
            'DIRECT',
          ],
        },
        {
          'name': autoGroup,
          'type': 'url-test',
          'proxies': names,
          'url': probeUrl,
          'interval': 300,
          'tolerance': 50,
        },
      ],
      'rules': ['MATCH,$selectGroup'],
    };
  }

  static dynamic _deepCopy(dynamic value) {
    if (value is Map) {
      return {
        for (final e in value.entries) e.key.toString(): _deepCopy(e.value),
      };
    }
    if (value is List) return [for (final v in value) _deepCopy(v)];
    return value;
  }
}
