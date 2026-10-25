import 'dart:convert';
import 'dart:io';

Map<String, dynamic> _merge(
  Map<String, dynamic> base,
  Map<String, dynamic> overlay,
) {
  final result = Map<String, dynamic>.from(base);
  for (final entry in overlay.entries) {
    final before = result[entry.key];
    final after = entry.value;
    result[entry.key] =
        before is Map<String, dynamic> && after is Map<String, dynamic>
        ? _merge(before, after)
        : after;
  }
  return result;
}

Future<String> exportLegacyProfiles(
  ({String source, String destination}) paths,
) async {
  final source = File(paths.source);
  if (await source.length() > 20 * 1024 * 1024) {
    throw const FormatException('File exceeds 20 MiB');
  }
  final decoded = jsonDecode(await source.readAsString());
  if (decoded is! Map<String, dynamic> || decoded['profiles'] is! List) {
    throw const FormatException('Not a Hotaru 0.4 profiles.json');
  }
  final profiles = decoded['profiles'] as List;
  if (profiles.isEmpty) throw const FormatException('No profiles');
  final output = Directory(paths.destination);
  if (await output.exists()) {
    throw const FileSystemException('Destination already exists');
  }
  await output.create(recursive: true);
  await source.copy('${output.path}/original-profiles.json');
  final manifest = <Map<String, dynamic>>[];
  for (final (index, raw) in profiles.indexed) {
    if (raw is! Map<String, dynamic> ||
        raw['config'] is! Map<String, dynamic>) {
      continue;
    }
    var config = Map<String, dynamic>.from(raw['config'] as Map);
    if (raw['mode'] == 'nodesOnly') {
      final names = [
        for (final node in config['proxies'] as List? ?? [])
          if (node is Map && node['name'] is String) node['name'] as String,
      ];
      final providers = (config['proxy-providers'] as Map? ?? {}).keys.toList();
      config = {
        ...config,
        'proxy-groups': [
          {
            'name': 'HOTARU',
            'type': 'select',
            'proxies': ['DIRECT', ...names],
            if (providers.isNotEmpty) 'use': providers,
          },
        ],
        'rules': ['MATCH,HOTARU'],
      };
    }
    config = _merge(
      config,
      Map<String, dynamic>.from(raw['merge'] as Map? ?? {}),
    );
    final filename = 'profile-${index + 1}.json';
    await File(
      '${output.path}/$filename',
    ).writeAsString(jsonEncode(config), flush: true);
    final script = raw['script'];
    if (script is String && script.isNotEmpty) {
      await File(
        '${output.path}/profile-${index + 1}.js',
      ).writeAsString(script, flush: true);
    }
    manifest.add({
      'file': filename,
      'name': raw['name'],
      'sourceUrl': raw['sourceUrl'],
      'sourceUrls': raw['sourceUrls'],
      'scriptExported': script is String && script.isNotEmpty,
    });
  }
  await File(
    '${output.path}/manifest.json',
  ).writeAsString(jsonEncode(manifest), flush: true);
  return output.path;
}
