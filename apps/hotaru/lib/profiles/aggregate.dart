/// Aggregated subscriptions: several subscription URLs merged into one
/// node list that behaves like a single profile.
///
/// Aggregation is deliberately nodes-only. Full Mihomo configs carry
/// proxy-groups, rules and providers whose names would collide across
/// sources; merging those silently would change routing. When a source
/// yields a full config, only its proxies are taken and the rest is noted
/// by the caller (the merged profile's mode is always nodesOnly).
library;

/// Parses the aggregate dialog's URL box: one subscription URL per line.
/// Throws [FormatException] naming the offending line for anything that is
/// not an absolute http(s) URL.
List<String> parseAggregateUrls(String text) {
  final urls = <String>[];
  final lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.isEmpty) continue;
    final uri = Uri.tryParse(line);
    if (uri == null ||
        !uri.isAbsolute ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw FormatException('第 ${i + 1} 行不是有效的 HTTP/HTTPS 订阅地址：$line');
    }
    urls.add(line);
  }
  if (urls.isEmpty) throw const FormatException('请至少填写一个订阅地址。');
  return urls;
}

/// Merges per-source proxy lists into one `{'proxies': [...]}` config.
///
/// Nodes keep their source order. A name already taken is renamed with its
/// source label (`name（来源）`, then `name（来源 2）` …) instead of silently
/// dropping one of the two nodes — dropping would lose a paid node.
/// Two nodes with the same name *and* identical server/port/type are
/// treated as the same node and kept once.
Map<String, dynamic> mergeAggregateConfigs(
  List<({String label, Map<String, dynamic> config})> sources,
) {
  final merged = <Map<String, dynamic>>[];
  final seen = <String>{};
  final identities = <String>{};
  for (final source in sources) {
    final proxies = source.config['proxies'];
    if (proxies is! List) continue;
    for (final raw in proxies) {
      if (raw is! Map<String, dynamic>) continue;
      final name = raw['name'];
      if (name is! String || name.isEmpty) continue;
      final identity = '${raw['type']}|${raw['server']}|${raw['port']}|$name';
      if (identities.contains(identity)) continue;
      identities.add(identity);
      var finalName = name;
      if (seen.contains(finalName)) {
        finalName = '$name（${source.label}）';
        var n = 2;
        while (seen.contains(finalName)) {
          finalName = '$name（${source.label} $n）';
          n++;
        }
      }
      seen.add(finalName);
      merged.add({...raw, 'name': finalName});
    }
  }
  return {'proxies': merged};
}
