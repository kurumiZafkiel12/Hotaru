import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/config/clash_dns.dart';
import 'package:hotaru/core/config/dns.dart';
import 'package:hotaru/core/config/profile.dart';
import 'package:hotaru/core/routing_mode.dart';
import 'package:hotaru/core/sing_box/config_builder.dart';

Map<String, Object?> settings(String server) => {
  'enable': true,
  'nameserver': [server],
  'use-hosts': false,
  'use-system-hosts': false,
};

CoreProfileSpec profile(CoreDnsSpec? dns, {bool hostname = false}) =>
    CoreProfileSpec(
      nodes: [
        const CoreNodeSpec(tag: 'direct', protocol: CoreNodeProtocol.direct),
        if (hostname)
          const CoreNodeSpec(
            tag: 'proxy',
            protocol: CoreNodeProtocol.http,
            server: 'proxy.invalid',
            port: 8080,
          ),
      ],
      selectors: [],
      finalOutbound: 'direct',
      dns: dns,
    );

const listeners = CoreListenerSpec(
  mixedPort: 17890,
  controllerPort: 19090,
  secret: 'fixture',
  dnsPort: 15353,
);

void main() {
  test('imports supported transports with explicit endpoint bootstrap', () {
    for (final entry in {
      '192.0.2.1': CoreDnsProtocol.udp,
      'tcp://192.0.2.1:5353': CoreDnsProtocol.tcp,
      'tls://192.0.2.1': CoreDnsProtocol.tls,
      'https://dns.invalid/dns-query': CoreDnsProtocol.https,
      '2001:db8::1': CoreDnsProtocol.udp,
      'system': CoreDnsProtocol.local,
      'system://': CoreDnsProtocol.local,
    }.entries) {
      final result = importClashDns({
        ...settings(entry.key),
        'default-nameserver': ['192.0.2.2'],
      });
      expect(result.issues, isEmpty, reason: entry.key);
      expect(result.dns!.servers.last.protocol, entry.value);
      if (entry.value == CoreDnsProtocol.https) {
        expect(result.dns!.servers.last.addressResolver, 'dns-bootstrap');
      }
    }
  });

  test(
    'unsupported policies and ambiguous upstreams fail instead of degrading',
    () {
      for (final extra in <Map<String, Object?>>[
        {
          'fallback': ['192.0.2.2'],
        },
        {
          'nameserver-policy': {'+.invalid': '192.0.2.2'},
        },
        {'enhanced-mode': 'unsupported'},
        {'respect-rules': true},
        {'prefer-h3': true},
        {'nameserver': List.filled(17, '192.0.2.1')},
        {'unknown-option': <String, Object?>{}},
        {
          'nameserver': ['https://dns.invalid/dns-query'],
        },
        {
          'nameserver': ['https://192.0.2.1/dns-query?token=unsupported'],
        },
        {
          'nameserver': ['udp://name:password@192.0.2.1'],
        },
      ]) {
        final result = importClashDns({...settings('192.0.2.1'), ...extra});
        expect(result.dns, isNull, reason: extra.toString());
        expect(
          result.issues.any(
            (issue) => issue.severity == CoreConfigIssueSeverity.error,
          ),
          isTrue,
        );
      }
      expect(
        importClashDns({...settings('192.0.2.1'), 'enable': false}).dns,
        isNull,
      );
    },
  );

  test(
    'parallel pools retain every upstream and require distinct owned listeners',
    () async {
      final imported = importClashDns({
        ...settings('192.0.2.1'),
        'nameserver': [
          'https://one.invalid/dns-query',
          'https://two.invalid/dns-query',
        ],
        'default-nameserver': ['192.0.2.3', '192.0.2.4'],
        'proxy-server-nameserver': ['192.0.2.5', '192.0.2.6'],
      });
      expect(imported.issues, isEmpty);
      final dns = imported.dns!;
      expect(dns.servers, hasLength(6));
      expect(dns.groups.map((group) => group.tag), [
        'dns-bootstrap',
        'dns-main',
        'dns-proxy',
      ]);
      final ports = {
        'dns-bootstrap': 15400,
        'dns-main': 15401,
        'dns-proxy': 15402,
      };
      CoreListenerSpec config(Map<String, int> ports, {bool enabled = true}) =>
          CoreListenerSpec(
            mixedPort: 17890,
            controllerPort: 19090,
            secret: 'fixture',
            inboundsEnabled: enabled,
            dnsGroups: CoreDnsGroupListeners(ports),
          );
      for (final invalid in [
        <String, int>{},
        {...ports, 'dns-main': 15400},
        {...ports, 'dns-main': 17890},
        {...ports, 'dns-main': 0},
        {...ports, 'unexpected': 15500},
      ]) {
        final built = await SingBoxConfigBuilder().build(
          profile(dns),
          config(invalid),
        );
        expect(built.json, isNull);
      }
      final built = await SingBoxConfigBuilder().build(
        profile(dns),
        config(ports, enabled: false),
      );
      expect(built.issues, isEmpty);
      final document = jsonDecode(built.json!);
      final inbounds = document['inbounds'] as List;
      expect(inbounds, hasLength(3));
      expect(
        inbounds.every((dynamic inbound) => inbound['listen'] == '127.0.0.1'),
        isTrue,
      );
      expect(document['dns']['servers'], hasLength(9));
      expect(document['route']['default_domain_resolver'], 'dns-main');
      final modes = config(ports)
          .withInbounds(false)
          .withRuntime(
            enabled: true,
            mode: CoreRoutingMode.global,
            globalSelection: null,
          );
      expect(modes.dnsGroups!.ports, ports);
    },
  );

  test('owned DNS inbound and TUN hijack precede all profile rules', () async {
    final dns = importClashDns(settings('192.0.2.1')).dns!;
    final result = await SingBoxConfigBuilder().build(
      profile(dns),
      CoreListenerSpec(
        mixedPort: 17890,
        controllerPort: 19090,
        secret: 'fixture',
        dnsPort: 15353,
        tun: CoreTunSpec(
          interfaceName: 'HotaruDnsFixture',
          addresses: ['198.18.8.1/30'],
          autoRoute: false,
          hijackDns: true,
        ),
      ),
    );
    expect(result.issues, isEmpty);
    final config = jsonDecode(result.json!);
    expect(config['dns']['strategy'], 'ipv4_only');
    expect(config['route']['default_domain_resolver'], 'dns-main');
    expect(config['route']['rules'][0]['inbound'], ['dns-in']);
    expect(config['route']['rules'][1]['port'], [53]);
    expect(config['inbounds'][0]['listen'], '127.0.0.1');
  });

  test(
    'rejects DNS recursion through a hostname proxy and missing owned DNS',
    () async {
      final dns = importClashDns(settings('udp://192.0.2.1#proxy')).dns!;
      final cycle = await SingBoxConfigBuilder().build(
        profile(dns, hostname: true),
        listeners,
      );
      expect(cycle.json, isNull);
      expect(
        cycle.issues.map((issue) => issue.code),
        contains('dns_dependency_cycle'),
      );
      final absent = await SingBoxConfigBuilder().build(
        profile(null),
        listeners,
      );
      expect(
        absent.issues.map((issue) => issue.code),
        contains('dns_required'),
      );
      final collision = await SingBoxConfigBuilder().build(
        profile(dns),
        const CoreListenerSpec(
          mixedPort: 17890,
          controllerPort: 19090,
          secret: 'fixture',
          dnsPort: 17890,
        ),
      );
      expect(
        collision.issues.map((issue) => issue.code),
        contains('invalid_dns_listener_port'),
      );
    },
  );

  test(
    'proxy hostname resolver remains separate from the final DNS resolver',
    () async {
      final imported = importClashDns({
        ...settings('https://dns.invalid/dns-query'),
        'default-nameserver': ['192.0.2.2'],
        'proxy-server-nameserver': ['tcp://192.0.2.3:5353'],
        'listen': '0.0.0.0:53',
      });
      expect(imported.issues.single.code, 'app_owned_setting_replaced');
      final result = await SingBoxConfigBuilder().build(
        profile(imported.dns, hostname: true),
        listeners,
      );
      expect(result.issues, isEmpty);
      final config = jsonDecode(result.json!);
      expect(config['route']['default_domain_resolver'], 'dns-main');
      expect(
        (config['outbounds'] as List).singleWhere(
          (dynamic node) => node['tag'] == 'proxy',
        )['domain_resolver'],
        'dns-proxy',
      );
      expect(config['dns']['servers'][1]['domain_resolver'], 'dns-bootstrap');
      expect(config['inbounds'][0]['listen'], '127.0.0.1');
    },
  );

  test(
    'direct IR rejects invalid server graphs and unused local options',
    () async {
      for (final dns in [
        CoreDnsSpec(servers: [], finalServer: 'missing'),
        CoreDnsSpec(
          servers: [
            const CoreDnsServerSpec(
              tag: 'a',
              protocol: CoreDnsProtocol.udp,
              server: 'dns.invalid',
              port: 53,
              addressResolver: 'b',
            ),
            const CoreDnsServerSpec(
              tag: 'b',
              protocol: CoreDnsProtocol.udp,
              server: 'other.invalid',
              port: 53,
              addressResolver: 'a',
            ),
          ],
          finalServer: 'a',
        ),
        CoreDnsSpec(
          servers: [
            const CoreDnsServerSpec(
              tag: 'a',
              protocol: CoreDnsProtocol.local,
              port: 53,
            ),
          ],
          finalServer: 'a',
        ),
        CoreDnsSpec(
          servers: [
            const CoreDnsServerSpec(
              tag: 'a',
              protocol: CoreDnsProtocol.udp,
              server: '192.0.2.1',
              port: 53,
              detour: 'missing',
            ),
          ],
          finalServer: 'a',
        ),
      ]) {
        final result = await SingBoxConfigBuilder().build(
          profile(dns),
          listeners,
        );
        expect(result.json, isNull);
        expect(result.issues, isNotEmpty);
      }
    },
  );

  test('implicit Clash hosts settings produce visible migration warnings', () {
    final imported = importClashDns({
      'enable': true,
      'nameserver': ['192.0.2.1'],
    });
    expect(imported.dns, isNotNull);
    expect(
      imported.issues.map((issue) => issue.code),
      containsAll(['dns_hosts_not_migrated', 'dns_system_hosts_not_migrated']),
    );
    expect(
      imported.issues.every(
        (issue) => issue.severity == CoreConfigIssueSeverity.warning,
      ),
      isTrue,
    );
  });

  final binary = Platform.environment['HOTARU_TEST_SING_BOX'];
  test(
    'official pinned engine accepts every supported DNS transport',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'hotaru-dns-check-',
      );
      try {
        for (final server in [
          '192.0.2.1',
          'tcp://192.0.2.1',
          '2001:db8::1',
          'tls://192.0.2.1',
          'https://dns.invalid/dns-query',
          'system',
        ]) {
          final dns = importClashDns({
            ...settings(server),
            'default-nameserver': ['192.0.2.2'],
          }).dns!;
          final result = await SingBoxConfigBuilder().build(
            profile(dns),
            listeners,
          );
          expect(result.issues, isEmpty);
          final file = File('${directory.path}/config.json');
          await file.writeAsString(result.json!);
          final check = await Process.run(binary!, ['check', '-c', file.path]);
          expect(check.exitCode, 0, reason: '${check.stdout}\n${check.stderr}');
        }
      } finally {
        await directory.delete(recursive: true);
      }
    },
    skip: binary == null
        ? 'Set HOTARU_TEST_SING_BOX to validate pinned engine'
        : false,
  );
}
