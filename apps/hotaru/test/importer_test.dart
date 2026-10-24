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
        'trojan://pw@host:443?unknownParam=1',
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
  Map<String, dynamic> single(String input) =>
      (ProfileImporter.parse(input, ImportMode.nodesOnly).config['proxies']
                  as List)
              .single
          as Map<String, dynamic>;

  test('SS SIP002 base64 userinfo and plain userinfo', () {
    final a = single(
      'ss://YWVzLTI1Ni1nY206cGFzc3cwcmQ@ss.example.com:8388#ss-node',
    );
    expect(a['type'], 'ss');
    expect(a['cipher'], 'aes-256-gcm');
    expect(a['password'], 'passw0rd');
    expect(a['name'], 'ss-node');
    final b = single('ss://aes-128-gcm:p%40ss@ss.example.com:8389#plain');
    expect(b['cipher'], 'aes-128-gcm');
    expect(b['password'], 'p@ss');
  });
  test('SS legacy base64 authority', () {
    final n = single(
      'ss://YWVzLTEyOC1nY206c2VjcmV0QGV4YW1wbGUuY29tOjgzODg=#legacy',
    );
    expect(n['server'], 'example.com');
    expect(n['port'], 8388);
    expect(n['cipher'], 'aes-128-gcm');
    expect(n['password'], 'secret');
  });
  test('SS obfs plugin is mapped, unknown plugin rejected', () {
    final n = single(
      'ss://YWVzLTI1Ni1nY206cGFzc3cwcmQ@ss.example.com:8388'
      '/?plugin=obfs-local%3Bobfs%3Dhttp%3Bobfs-host%3Dcdn.example.com#x',
    );
    expect(n['plugin'], 'obfs');
    expect((n['plugin-opts'] as Map)['mode'], 'http');
    expect((n['plugin-opts'] as Map)['host'], 'cdn.example.com');
    expect(
      () => ProfileImporter.parse(
        'ss://YWVzLTI1Ni1nY206cGFzc3cwcmQ@ss.example.com:8388/?plugin=nope',
        ImportMode.nodesOnly,
      ),
      throwsFormatException,
    );
  });
  test('VMess base64 JSON with ws+tls', () {
    final n = single(
      'vmess://eyJ2IjoiMiIsInBzIjoidm1lc3Mtd3MiLCJhZGQiOiJ2bS5leGFtcGxlLmNvbSIsInBvcnQiOiI0NDMiLCJpZCI6ImI4MzEzODFkLTYzMjQtNGQ1My1hZDRmLThjZGE0OGIzMDgxMSIsImFpZCI6IjAiLCJzY3kiOiJhdXRvIiwibmV0Ijoid3MiLCJ0eXBlIjoibm9uZSIsImhvc3QiOiJjZG4uZXhhbXBsZS5jb20iLCJwYXRoIjoiL3JheSIsInRscyI6InRscyIsInNuaSI6InZtLmV4YW1wbGUuY29tIn0=',
    );
    expect(n['type'], 'vmess');
    expect(n['name'], 'vmess-ws');
    expect(n['uuid'], 'b831381d-6324-4d53-ad4f-8cda48b30811');
    expect(n['alterId'], 0);
    expect(n['network'], 'ws');
    expect(n['tls'], true);
    expect(n['servername'], 'vm.example.com');
    expect((n['ws-opts'] as Map)['path'], '/ray');
    expect(
      ((n['ws-opts'] as Map)['headers'] as Map)['Host'],
      'cdn.example.com',
    );
  });
  test('VLESS reality and ws forms', () {
    final r = single(
      'vless://b831381d-6324-4d53-ad4f-8cda48b30811@vl.example.com:443'
      '?security=reality&sni=www.example.com&fp=chrome'
      '&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=ab12'
      '&flow=xtls-rprx-vision#reality-node',
    );
    expect(r['type'], 'vless');
    expect(r['tls'], true);
    expect(r['flow'], 'xtls-rprx-vision');
    expect(
      (r['reality-opts'] as Map)['public-key'],
      'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    );
    expect((r['reality-opts'] as Map)['short-id'], 'ab12');
    final w = single(
      'vless://uuid-1@vl.example.com:80?type=ws&host=cdn.example.com&path=%2Fws#ws-node',
    );
    expect(w['network'], 'ws');
    expect((w['ws-opts'] as Map)['path'], '/ws');
    expect(w.containsKey('tls'), isFalse);
  });
  test('Hysteria2 with salamander obfs and insecure flag', () {
    final n = single(
      'hysteria2://secret@hy.example.com:443?insecure=1&sni=hy.example.com'
      '&obfs=salamander&obfs-password=obfspw#hy-node',
    );
    expect(n['type'], 'hysteria2');
    expect(n['password'], 'secret');
    expect(n['skip-cert-verify'], true);
    expect(n['obfs'], 'salamander');
    expect(n['obfs-password'], 'obfspw');
    // hy2:// alias, no obfs
    expect(single('hy2://pw@hy.example.com:8443')['port'], 8443);
  });
  test('Trojan ws transport and skip-cert-verify', () {
    final n = single(
      'trojan://pw@tr.example.com:443?allowInsecure=1&type=ws'
      '&host=cdn.example.com&path=%2Ftr#tr-ws',
    );
    expect(n['skip-cert-verify'], true);
    expect(n['network'], 'ws');
    expect((n['ws-opts'] as Map)['path'], '/tr');
  });
  test('Base64 subscription decodes to a URI list', () {
    final result = ProfileImporter.parse(
      'c29ja3M1Oi8vMTI3LjAuMC4xOjEwODAjbG9jYWwKc3M6Ly9ZV1Z6TFRJMU5pMW5ZMjA2Y0dGemMzY3djbVFAc3MuZXhhbXBsZS5jb206ODM4OCNzcy1ub2Rl',
      ImportMode.nodesOnly,
    );
    expect(result.nodeCount, 2);
  });
  test('new protocols reject invalid input instead of dropping fields', () {
    for (final s in [
      'vless://uuid@host:443?encryption=chacha', // unsupported encryption
      'vless://uuid@host:443?security=reality', // reality without pbk
      'vless://uuid@host:443?flow=xtls-rprx-direct', // unknown flow
      'hysteria2://pw@host:443?obfs=salamander', // obfs without password
      'hysteria2://pw@host:443?obfs=tiger', // unknown obfs
      'vmess://aGVsbG8=', // base64 but not JSON
      'ss://@host:8388', // empty credentials
    ]) {
      expect(
        () => ProfileImporter.parse(s, ImportMode.nodesOnly),
        throwsFormatException,
        reason: s,
      );
    }
  });
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
