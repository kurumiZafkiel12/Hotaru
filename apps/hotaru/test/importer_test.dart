import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/profiles/importer.dart';

void main() {
  const yaml =
      'proxies:\n  - {name: sample, type: socks5, server: localhost, port: 1080}\nrules: [MATCH,DIRECT]';
  test('two modes preserve or strip surrounding config', () {
    expect(
      ProfileImporter.parse(
        yaml,
        ImportMode.fullConfig,
      ).config.containsKey('rules'),
      true,
    );
    expect(ProfileImporter.parse(yaml, ImportMode.nodesOnly).config.keys, [
      'proxies',
    ]);
  });
  test('URI decodes credentials and IPv6', () {
    final n =
        (ProfileImporter.parse(
                  'socks5://u:p%40ss@[::1]:1080#test',
                  ImportMode.nodesOnly,
                ).config['proxies']
                as List)
            .single;
    expect(n['password'], 'p@ss');
    expect(n['port'], 1080);
  });
  test(
    'reject malformed, duplicate, unsupported parameters and huge input',
    () {
      for (final s in [
        '',
        'proxies: []',
        'socks5://host:0',
        'trojan://pw@host:443?allowInsecure=1',
        'socks5://host:1080\nsocks5://host:1080',
        'a' * (ProfileImporter.maxBytes + 1),
      ]) {
        expect(
          () => ProfileImporter.parse(s, ImportMode.nodesOnly),
          throwsFormatException,
        );
      }
    },
  );
  test(
    'HTTPS subscription policy rejects insecure input before networking',
    () async {
      await expectLater(
        ProfileImporter.fetch(Uri.parse('http://localhost/sub')),
        throwsFormatException,
      );
    },
  );
}
