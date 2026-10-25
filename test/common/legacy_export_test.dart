import 'dart:convert';
import 'dart:io';

import 'package:hotaru/common/legacy_export.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'legacy export preserves original, routing, merge and unexecuted script',
    () async {
      final root = await Directory.systemTemp.createTemp('hotaru-legacy-');
      addTearDown(() => root.delete(recursive: true));
      final source = File('${root.path}/profiles.json');
      final original = jsonEncode({
        'profiles': [
          {
            'name': 'full',
            'config': {
              'rules': ['MATCH,DIRECT'],
              'dns': {'enable': true},
            },
            'merge': {
              'dns': {'ipv6': true},
            },
            'script': 'throw new Error("must not execute");',
            'sourceUrl': 'https://example.com/sub',
          },
          {
            'name': 'nodes',
            'mode': 'nodesOnly',
            'config': {
              'proxies': [
                {
                  'name': 'JP',
                  'type': 'socks5',
                  'server': 'localhost',
                  'port': 1080,
                },
              ],
            },
          },
        ],
      });
      await source.writeAsString(original);
      final destination = '${root.path}/output';
      await exportLegacyProfiles((
        source: source.path,
        destination: destination,
      ));
      expect(await source.readAsString(), original);
      expect(
        await File('$destination/original-profiles.json').readAsString(),
        original,
      );
      final full =
          jsonDecode(await File('$destination/profile-1.json').readAsString())
              as Map;
      expect(full['rules'], ['MATCH,DIRECT']);
      expect(full['dns'], {'enable': true, 'ipv6': true});
      expect(
        await File('$destination/profile-1.js').readAsString(),
        contains('must not execute'),
      );
      final nodes =
          jsonDecode(await File('$destination/profile-2.json').readAsString())
              as Map;
      expect(nodes['rules'], ['MATCH,HOTARU']);
      await expectLater(
        exportLegacyProfiles((source: source.path, destination: destination)),
        throwsA(isA<FileSystemException>()),
      );
    },
  );
}
