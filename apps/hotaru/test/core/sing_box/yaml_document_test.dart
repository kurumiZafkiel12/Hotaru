import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/config/clash_importer.dart';
import 'package:hotaru/core/config/clash_subscription.dart';
import 'package:hotaru/core/config/yaml_document.dart';
import 'package:hotaru/core/config/profile.dart';
import 'package:hotaru/core/sing_box/config_builder.dart';

void main() {
  test(
    'a compact recursive alias expansion is stopped before materializing its full graph',
    () {
      final source =
          'a: &a [padding]\nb: &b [${List.filled(32, '*a').join(',')}]\nc: [${List.filled(32, '*b').join(',')}]';
      expect(
        () => decodeCoreYaml(source, maxValues: 100),
        throwsFormatException,
      );
    },
  );

  final binary = Platform.environment['HOTARU_TEST_SING_BOX'];
  test(
    'pinned engine accepts inherited nodes and preserved Reality short ID',
    () async {
      final imported = await ClashProfileImporter().import('''
x-defaults: &defaults {type: http, server: 127.0.0.1, port: 1080}
proxies:
  - {<<: *defaults, name: A}
  - {<<: *defaults, name: B, port: '1081'}
  - name: Reality
    type: vless
    server: 127.0.0.1
    port: 443
    uuid: f0db417e-1460-4a2b-b37f-e62a1ab9d91c
    tls: true
    client-fingerprint: chrome
    reality-opts: {public-key: SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc, short-id: 0123}
proxy-groups: [{name: selected, type: select, proxies: [A, B, Reality]}]
rules: ['MATCH,selected']
''');
      expect(imported.profile, isNotNull);
      expect(
        imported.issues.every(
          (issue) => issue.severity == CoreConfigIssueSeverity.warning,
        ),
        isTrue,
      );
      expect(
        imported.profile!.nodes
            .singleWhere((node) => node.tag == 'Reality')
            .tls!
            .realityShortId,
        '0123',
      );
      final built = await SingBoxConfigBuilder().build(
        imported.profile!,
        const CoreListenerSpec(
          mixedPort: 17890,
          controllerPort: 19090,
          secret: 'fixture',
        ),
      );
      expect(built.issues, isEmpty);
      final directory = await Directory.systemTemp.createTemp(
        'hotaru-yaml-check-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = await File(
        '${directory.path}/config.json',
      ).writeAsString(built.json!);
      final result = await Process.run(binary!, ['check', '-c', file.path]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
    },
    skip: binary == null
        ? 'Set HOTARU_TEST_SING_BOX to a pinned engine'
        : false,
  );

  test('merge keys honor explicit values and first-map precedence', () {
    final document =
        decodeCoreYaml('''
first: &first {name: first, port: 443, nested: {tls: true}}
second: &second {name: second, port: 80, server: example.org}
before: {name: explicit, <<: [*first, *second]}
after: {<<: [*first, *second], name: explicit}
''')
            as Map;
    expect(document['before'], document['after']);
    expect(document['after'], {
      'name': 'explicit',
      'port': 443,
      'nested': {'tls': true},
      'server': 'example.org',
    });
    (document['after']['nested'] as Map)['tls'] = false;
    expect(document['first']['nested']['tls'], isTrue);
    expect(document['before']['nested']['tls'], isTrue);
  });

  test(
    'quoted merge keys remain ordinary data and scalar types are retained',
    () {
      final document =
          decodeCoreYaml('''
base: &base {port: 443}
value: {'<<': *base, text: '0001', number: 1, flag: false}
''')
              as Map;
      expect(document['value'], {
        '<<': {'port': 443},
        'text': '0001',
        'number': 1,
        'flag': false,
      });
    },
  );

  test('cycles, non-mapping merges and complex keys fail explicitly', () {
    for (final source in [
      'value: &self {<<: *self}',
      'value: {<<: 1}',
      'value: {<<: [{port: 1}, 2]}',
      '? [a, b]\n: value',
    ]) {
      expect(
        () => decodeCoreYaml(source),
        throwsFormatException,
        reason: source,
      );
    }
  });

  test('alias expansion, encoded size and depth have independent bounds', () {
    const source = 'base: &base {data: abcdef}\nvalues: [*base, *base, *base]';
    expect(() => decodeCoreYaml(source, maxValues: 8), throwsFormatException);
    expect(
      () => decodeCoreYaml(source, maxExpandedBytes: 100),
      throwsFormatException,
    );
    expect(
      () => decodeCoreYaml('a: {b: {c: value}}', maxDepth: 2),
      throwsFormatException,
    );
    expect(() => decodeCoreYaml(source, maxValues: 0), throwsArgumentError);
    expect(
      () => decodeCoreYaml('x: ${'a' * (16 * 1024 * 1024)}'),
      throwsFormatException,
    );
  });

  test(
    'normal Clash imports inherit protocol fields without shared mutable maps',
    () async {
      final result = await ClashProfileImporter().import('''
proxies:
  - &base {name: A, type: ss, server: 127.0.0.1, port: 1080, cipher: aes-128-gcm, password: fixture}
  - {<<: *base, name: B, port: '1081'}
proxy-groups: [{name: selected, type: select, proxies: [A, B]}]
rules: ['MATCH,selected']
''');
      expect(result.issues, isEmpty);
      final nodes = result.profile!.nodes
          .where((node) => node.tag == 'A' || node.tag == 'B')
          .toList();
      expect(nodes.map((node) => node.port), [1080, 1081]);
      expect(
        nodes.every(
          (node) => node.cipher == 'aes-128-gcm' && node.password == 'fixture',
        ),
        isTrue,
      );
    },
  );

  test(
    'Reality short IDs preserve their literal hex spelling without coercing other numbers',
    () {
      final document =
          decodeCoreYaml(
                'reality-opts: {short-id: 0123}\nother: 123\nscientific: {short-id: 1e12}',
              )
              as Map;
      expect(document['reality-opts']['short-id'], '0123');
      expect(document['scientific']['short-id'], '1e12');
      expect(document['other'], 123);
    },
  );

  test(
    'extension templates are disclosed while their inherited fields remain effective',
    () async {
      final result = await ClashProfileImporter().import('''
x-defaults: &defaults {type: http, server: 127.0.0.1, port: 1080}
proxies: [{<<: *defaults, name: A}]
rules: ['MATCH,A']
''');
      expect(result.profile, isNotNull);
      expect(result.issues.single.code, 'metadata_field_ignored');
      expect(result.issues.single.severity.name, 'warning');
      expect(
        result.profile!.nodes.singleWhere((node) => node.tag == 'A').port,
        1080,
      );
    },
  );

  test(
    'provider payload merges use the same decoder and bad plans do no IO',
    () async {
      var requests = 0;
      final importer = ClashSubscriptionImporter(
        resolve: (_) async {
          requests++;
          return '''
proxies:
  - &base {name: A, type: http, server: 127.0.0.1, port: 1080}
  - {<<: *base, name: B, port: 1081}
''';
        },
      );
      final result = await importer.import('''
proxy-providers: {source: {type: http, url: 'https://provider.invalid/nodes'}}
proxy-groups: [{name: selected, type: select, use: [source]}]
rules: ['MATCH,selected']
''');
      expect(result.profile, isNotNull);
      expect(
        result.profile!.nodes.where((node) => node.tag == 'B').single.port,
        1081,
      );
      expect(requests, 1);
      final invalid = await importer.import(
        'proxy-providers: {source: &self {<<: *self}}',
      );
      expect(invalid.profile, isNull);
      expect(invalid.issues, isNotEmpty);
      expect(requests, 1);
    },
  );
}
