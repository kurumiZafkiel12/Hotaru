import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/common/task.dart';
import 'package:hotaru/core/config/yaml_document.dart';
import 'package:hotaru/core/config/application_settings.dart';
import 'package:hotaru/core/config/clash_importer.dart';
import 'package:hotaru/core/config/dns.dart';
import 'package:hotaru/core/config/profile.dart';
import 'package:hotaru/core/routing_mode.dart';
import 'package:hotaru/core/sing_box/config_builder.dart';
import 'package:hotaru/models/models.dart';

void main() {
  test(
    'actual application output keeps settings and stops injecting the unauthenticated legacy probe',
    () async {
      const state = MakeRealProfileState(
        profilesPath: '/fixture',
        profileId: 7,
        rawConfig: {
          'proxies': [
            {
              'name': 'fixture',
              'type': 'http',
              'server': '127.0.0.1',
              'port': 18080,
            },
          ],
          'proxy-groups': [
            {
              'name': 'group',
              'type': 'select',
              'proxies': ['fixture'],
            },
          ],
          'rules': ['MATCH,group'],
        },
        realPatchConfig: defaultClashConfig,
        appendSystemDns: false,
        proxyGroups: [],
        rules: [],
        addedRules: [],
        defaultUA: 'Hotaru-Fixture',
        scopedOutboundClients: true,
        authentication: ['alice:first:second'],
      );
      final built = await makeRealProfileTask(state);
      final legacy = await makeRealProfileTask(
        state.copyWith(scopedOutboundClients: false),
      );
      final legacyDocument = decodeCoreYaml(legacy.yaml) as Map;
      expect(legacyDocument['listeners'] as List, hasLength(1));
      expect(legacyDocument['proxy-groups'] as List, hasLength(2));
      final projection = await CoreApplicationSettings.parse(
        built.yaml,
        skipCertVerify: true,
      );
      expect(
        projection.issues.where(
          (issue) => issue.severity == CoreConfigIssueSeverity.error,
        ),
        isEmpty,
      );
      final settings = projection.settings!;
      expect(settings.inbound.users.single.username, 'alice');
      expect(settings.inbound.users.single.password, 'first:second');
      expect(settings.inbound.listen, '127.0.0.1');
      expect(settings.runtime.skipCertVerify, isTrue);
      expect(settings.runtime.resolveIpv6, isFalse);
      expect(settings.runtime.tcpKeepAliveSeconds, 15);
      expect(settings.runtime.tcpKeepAliveIntervalSeconds, 30);
      expect(settings.tun, isNull);
      expect(settings.mode, CoreRoutingMode.rule);
      expect(settings.userAgent, 'Hotaru-Fixture');
      final document = jsonDecode(settings.source) as Map<String, dynamic>;
      expect(document, isNot(contains('listeners')));
      expect((document['proxy-groups'] as List), hasLength(1));
      final imported = await ClashProfileImporter().import(settings.source);
      expect(
        imported.profile,
        isNotNull,
        reason: imported.issues
            .map((issue) => '${issue.code}:${issue.path}')
            .join('\n'),
      );
      expect(
        imported.profile!.dns!.groups.map((group) => group.tag),
        containsAll(['dns-main', 'dns-bootstrap']),
      );
      expect(imported.profile!.dns!.fakeIp, isNotNull);
      expect(imported.profile!.selectors.single.tag, 'group');
    },
  );

  test(
    'LAN, separate ports, routing mode and TUN settings become explicit native parameters',
    () async {
      final projection = await CoreApplicationSettings.parse(
        jsonEncode({
          'mixed-port': 17890,
          'port': 17891,
          'socks-port': 17892,
          'allow-lan': true,
          'bind-address': '::',
          'mode': 'global',
          'find-process-mode': 'always',
          'ipv6': true,
          'interface-name': 'Ethernet',
          'tun': {
            'enable': true,
            'device': 'Hotaru',
            'stack': 'mips',
            'auto-route': true,
            'dns-hijack': ['any:53'],
            'mtu': 1500,
            'route-address': ['0.0.0.0/0'],
            'route-exclude-address': ['192.168.0.0/16'],
          },
          'dns': {
            'enable': true,
            'listen': '0.0.0.0:1053',
            'nameserver': ['1.1.1.1'],
          },
        }),
        skipCertVerify: false,
      );
      final settings = projection.settings!;
      expect(settings.inbound.listen, '::');
      expect(settings.inbound.httpPort, 17891);
      expect(settings.inbound.socksPort, 17892);
      expect(settings.mode, CoreRoutingMode.global);
      expect(settings.runtime.findProcess, isTrue);
      expect(settings.runtime.defaultInterface, 'Ethernet');
      expect(settings.dnsPort, 1053);
      expect(settings.tun!.mtu, 1500);
      expect(settings.tun!.hijackDns, isTrue);
      expect(settings.tun!.addresses, [
        '172.19.0.1/30',
        'fdfe:dcba:9876::1/126',
      ]);
      expect(settings.tun!.routes, ['0.0.0.0/0']);
      expect(settings.tun!.excludedRoutes, ['192.168.0.0/16']);
      expect(
        projection.issues.map((issue) => issue.code),
        contains('native_tun_stack_changed'),
      );
      expect(
        projection.issues.every(
          (issue) => issue.severity == CoreConfigIssueSeverity.warning,
        ),
        isTrue,
      );
    },
  );

  for (final entry in <String, Object?>{
    'mixed-port': 0,
    'authentication': ['malformed'],
    'skip-auth-prefixes': ['127.0.0.1/32'],
    'find-process-mode': 'sometimes',
    'mode': 'unknown',
    'ipv6': 'yes',
    'redir-port': 1234,
    'tproxy-port': 1234,
    'routing-mark': 1,
    'hosts': {'host.example': '127.0.0.1'},
    'geo-auto-update': true,
    'geox-url': {'geoip': 'https://user:secret@example.com/a'},
    'profile': {'store-fake-ip': true},
    'sniffer': {'enable': true},
    'listeners': [
      {'type': 'mixed'},
    ],
    'tun': {'enable': true, 'stack': 'unknown'},
  }.entries) {
    test(
      'unsupported active application setting is blocked: ${entry.key}',
      () async {
        final result = await CoreApplicationSettings.parse(
          jsonEncode({entry.key: entry.value}),
          skipCertVerify: false,
        );
        expect(result.settings, isNull);
        expect(
          result.issues.any(
            (issue) => issue.severity == CoreConfigIssueSeverity.error,
          ),
          isTrue,
        );
        expect(
          result.issues.map((issue) => issue.path).join(),
          isNot(contains('secret')),
        );
      },
    );
  }

  test(
    'unrecognized fields stay in the document for strict import validation',
    () async {
      final result = await CoreApplicationSettings.parse(
        'mystery-option: true\nrules: ["MATCH,DIRECT"]',
        skipCertVerify: false,
      );
      expect(
        jsonDecode(result.settings!.source),
        containsPair('mystery-option', true),
      );
      final imported = await ClashProfileImporter().import(
        result.settings!.source,
      );
      expect(
        imported.issues.map((issue) => issue.code),
        contains('unsupported_field'),
      );
    },
  );

  test(
    'disabled DNS never creates a local listener and explicit bootstrap is preserved',
    () async {
      final disabled = await CoreApplicationSettings.parse(
        'dns: {enable: false, listen: "0.0.0.0:53"}',
        skipCertVerify: false,
      );
      expect(disabled.settings!.dnsPort, isNull);
      final explicit = await CoreApplicationSettings.parse(
        'dns: {enable: true, nameserver: [1.1.1.1], default-nameserver: []}',
        skipCertVerify: false,
      );
      expect(
        (jsonDecode(explicit.settings!.source)['dns']
            as Map)['default-nameserver'],
        isEmpty,
      );
      expect(
        (await ClashProfileImporter().import(
          explicit.settings!.source,
        )).profile,
        isNull,
      );
    },
  );

  final binary = Platform.environment['HOTARU_TEST_SING_BOX'];
  test(
    'projected runtime, authentication and TUN configuration pass the pinned native checker',
    () async {
      final result = await CoreApplicationSettings.parse(
        jsonEncode({
          'mixed-port': 17890,
          'port': 17891,
          'socks-port': 17892,
          'authentication': ['fixture:one:two'],
          'find-process-mode': 'always',
          'ipv6': false,
          'log-level': 'warning',
          'tun': {
            'enable': true,
            'stack': 'system',
            'device': 'Hotaru-Check',
            'mtu': 1500,
            'dns-hijack': ['any:53'],
          },
          'dns': {
            'enable': true,
            'listen': '127.0.0.1:1053',
            'nameserver': ['1.1.1.1'],
            'use-hosts': false,
            'use-system-hosts': false,
          },
          'rules': ['MATCH,DIRECT'],
        }),
        skipCertVerify: false,
      );
      final settings = result.settings!;
      final imported = await ClashProfileImporter().import(settings.source);
      final source = imported.profile!;
      final compiled = await SingBoxConfigBuilder().build(
        CoreProfileSpec(
          nodes: source.nodes,
          selectors: source.selectors,
          finalOutbound: source.finalOutbound,
          rules: source.rules,
          ruleSets: source.ruleSets,
          dns: source.dns,
          runtime: settings.runtime,
        ),
        CoreListenerSpec(
          mixedPort: settings.mixedPort,
          controllerPort: 19090,
          secret: 'private-fixture',
          inbound: settings.inbound,
          tun: settings.tun,
          dnsPort: settings.dnsPort,
          dnsGroups: CoreDnsGroupListeners({
            for (var i = 0; i < source.dns!.groups.length; i++)
              source.dns!.groups[i].tag: 19100 + i,
          }),
        ),
      );
      expect(compiled.issues, isEmpty);
      final directory = await Directory.systemTemp.createTemp(
        'hotaru-app-check-',
      );
      try {
        final file = await File(
          '${directory.path}/config.json',
        ).writeAsString(compiled.json!);
        final checked = await Process.run(binary!, ['check', '-c', file.path]);
        expect(checked.exitCode, 0, reason: '${checked.stderr}');
      } finally {
        await directory.delete(recursive: true);
      }
    },
    skip: binary == null
        ? 'Set HOTARU_TEST_SING_BOX for native settings check'
        : false,
  );
}
