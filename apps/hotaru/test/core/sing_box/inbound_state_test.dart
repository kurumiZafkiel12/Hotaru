import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/adapter.dart';
import 'package:hotaru/core/config/dns.dart';
import 'package:hotaru/core/config/profile.dart';
import 'package:hotaru/core/config/probe_listener.dart';
import 'package:hotaru/core/routing_mode.dart';
import 'package:hotaru/core/sing_box/clash_api_adapter.dart';
import 'package:hotaru/core/sing_box/config_builder.dart';

import 'loopback_proxy_fixture.dart';

CoreProfileSpec _profile() => CoreProfileSpec(
  nodes: const [CoreNodeSpec(tag: 'direct', protocol: CoreNodeProtocol.direct)],
  selectors: [
    CoreSelectorSpec(tag: 'selected', members: ['direct']),
  ],
  finalOutbound: 'selected',
  dns: CoreDnsSpec(
    servers: const [
      CoreDnsServerSpec(tag: 'local', protocol: CoreDnsProtocol.local),
    ],
    finalServer: 'local',
  ),
);

CoreListenerSpec _settings({
  int mixed = 17890,
  int api = 19090,
  int probe = 17891,
  int dns = 15353,
}) => CoreListenerSpec(
  mixedPort: mixed,
  controllerPort: api,
  secret: 'idle-fixture',
  dnsPort: dns,
  probe: CoreProbeListenerSpec(
    port: probe,
    secret: 'idle-probe-fixture-12345678901234567890',
  ),
  tun: CoreTunSpec(
    interfaceName: 'HotaruIdleFixture',
    addresses: ['198.18.99.1/30'],
    autoRoute: false,
    hijackDns: true,
  ),
);

void main() {
  test(
    'runtime policy defaults compile explicitly and invalid global selections cannot activate',
    () async {
      final listeners = _settings().withRuntime(
        enabled: false,
        mode: CoreRoutingMode.global,
        globalSelection: 'direct',
      );
      final builder = SingBoxConfigBuilder();
      final result = await builder.build(_profile(), listeners);
      expect(result.issues, isEmpty);
      final configuration = jsonDecode(result.json!);
      expect(
        configuration['experimental']['clash_api']['default_mode'],
        'global',
      );
      expect(
        (configuration['outbounds'] as List).singleWhere(
          (entry) => entry['tag'] == 'Hotaru GLOBAL',
        )['default'],
        'direct',
      );
      final resumed = listeners.withInbounds(true);
      expect(resumed.initialMode, CoreRoutingMode.global);
      expect(resumed.globalSelection, 'direct');
      final invalid = await builder.build(
        _profile(),
        listeners.withRuntime(
          enabled: false,
          mode: CoreRoutingMode.rule,
          globalSelection: 'missing',
        ),
      );
      expect(invalid.json, isNull);
      expect(invalid.issues.single.code, 'invalid_global_selection');
    },
  );

  test(
    'disabling inbounds retains requested settings and authenticated control without data listeners',
    () async {
      final active = _settings();
      final idle = active.withInbounds(false);
      expect(idle.inboundsEnabled, isFalse);
      expect(idle.activeProbe, isNull);
      expect(idle.activeTun, isNull);
      expect(idle.activeDnsPort, isNull);
      expect(idle.probe, same(active.probe));
      expect(idle.tun, same(active.tun));
      final builder = SingBoxConfigBuilder();
      final quiet = await builder.build(_profile(), idle);
      expect(quiet.issues, isEmpty);
      final config = jsonDecode(quiet.json!);
      expect(config['inbounds'], isEmpty);
      expect(config['experimental']['clash_api']['secret'], 'idle-fixture');
      expect(
        (config['route']['rules'] as List).any(
          (entry) => entry.containsKey('inbound'),
        ),
        isFalse,
      );
      expect(config['route'].containsKey('auto_detect_interface'), isFalse);
      final restored = await builder.build(_profile(), idle.withInbounds(true));
      expect(restored.issues, isEmpty);
      expect(
        (jsonDecode(restored.json!)['inbounds'] as List).map(
          (entry) => entry['type'],
        ),
        ['http', 'direct', 'mixed', 'tun'],
      );
    },
  );

  test(
    'disabled settings still validate their eventual listener configuration',
    () async {
      final invalid = await SingBoxConfigBuilder().build(
        _profile(),
        const CoreListenerSpec(
          mixedPort: 17890,
          controllerPort: 17890,
          secret: 'fixture',
          inboundsEnabled: false,
        ),
      );
      expect(invalid.json, isNull);
      expect(
        invalid.issues.map((issue) => issue.code),
        contains('invalid_listener_ports'),
      );
    },
  );

  final binary = Platform.environment['HOTARU_TEST_SING_BOX'];
  final controlled = Platform.environment['HOTARU_TEST_SING_BOX_HOST'] == '1';
  test(
    'real engine keeps authenticated control while occupied data ports remain untouched',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'hotaru-control-only-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final mixed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final dns = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      var foreignConnections = 0;
      for (final socket in [mixed, probe, dns]) {
        addTearDown(socket.close);
        socket.listen((client) {
          foreignConnections++;
          client.destroy();
        });
      }
      final api = await freeLoopbackPort();
      final settings =
          _settings(
            mixed: mixed.port,
            api: api,
            probe: probe.port,
            dns: dns.port,
          ).withRuntime(
            enabled: false,
            mode: CoreRoutingMode.global,
            globalSelection: 'direct',
          );
      final built = await SingBoxConfigBuilder().build(_profile(), settings);
      expect(built.issues, isEmpty);
      expect(jsonDecode(built.json!)['inbounds'], isEmpty);
      final file = await File(
        '${directory.path}/config.json',
      ).writeAsString(built.json!);
      final process = await Process.start(binary!, [
        'run',
        '-c',
        file.path,
        if (controlled) '--stdio-control',
      ]);
      var exited = false;
      final exit = process.exitCode.then((value) {
        exited = true;
        return value;
      });
      final output = <String>[];
      final readers = [
        process.stdout.transform(utf8.decoder).forEach(output.add),
        process.stderr.transform(utf8.decoder).forEach(output.add),
      ];
      addTearDown(() async {
        if (!exited) {
          if (controlled) {
            process.stdin.writeln('stop');
            await process.stdin.flush();
          } else {
            process.kill();
          }
        }
        try {
          await exit.timeout(const Duration(seconds: 5));
        } on TimeoutException {
          process.kill(ProcessSignal.sigkill);
          await exit;
        }
        await Future.wait(readers);
      });
      final adapter = SingBoxClashApiAdapter(
        endpoint: Uri.parse('http://127.0.0.1:$api'),
        secret: settings.secret,
        probe: settings.activeProbe,
        probeOutbounds: ['direct', 'selected'],
      );
      addTearDown(adapter.close);
      var ready = false;
      for (var attempt = 0; attempt < 100; attempt++) {
        try {
          await adapter.version();
          ready = true;
          break;
        } catch (_) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
      expect(ready, isTrue, reason: output.join());
      expect(await adapter.routingMode(), CoreRoutingMode.global);
      expect(
        (await adapter.outbounds())
            .singleWhere((entry) => entry.name == 'Hotaru GLOBAL')
            .selected,
        'direct',
      );
      await adapter.setRoutingMode(CoreRoutingMode.rule);
      await adapter.selectOutbound('selected', 'direct');
      expect(
        (await adapter.outbounds())
            .singleWhere((entry) => entry.name == 'selected')
            .selected,
        'direct',
      );
      await adapter.setRoutingMode(CoreRoutingMode.global);
      expect(await adapter.routingMode(), CoreRoutingMode.global);
      var called = false;
      await expectLater(
        adapter.withOutboundClient('direct', (_) async {
          called = true;
        }),
        throwsA(
          isA<CoreAdapterException>().having(
            (error) => error.code,
            'code',
            'outbound_http_unavailable',
          ),
        ),
      );
      expect(called, isFalse);
      expect(foreignConnections, 0);
      stdout.writeln(
        jsonEncode({
          'control_only_api_live': true,
          'initial_runtime_mode_and_selection': true,
          'inactive_probe_refused': true,
          'occupied_data_ports_untouched': true,
          'controlled_host': controlled,
        }),
      );
    },
    skip: binary == null
        ? 'Set HOTARU_TEST_SING_BOX to a pinned engine'
        : false,
  );
}
