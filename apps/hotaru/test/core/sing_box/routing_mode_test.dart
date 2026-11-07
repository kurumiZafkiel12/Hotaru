import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/config/mode_outbounds.dart';
import 'package:hotaru/core/config/profile.dart';
import 'package:hotaru/core/config/probe_listener.dart';
import 'package:hotaru/core/config/route_preview.dart';
import 'package:hotaru/core/routing_mode.dart';
import 'package:hotaru/core/sing_box/clash_api_adapter.dart';
import 'package:hotaru/core/sing_box/config_builder.dart';

import 'loopback_proxy_fixture.dart';

CoreProfileSpec _profile(int first, int second) => CoreProfileSpec(
  nodes: [
    CoreNodeSpec(
      tag: 'A',
      protocol: CoreNodeProtocol.http,
      server: '127.0.0.1',
      port: first,
    ),
    CoreNodeSpec(
      tag: 'B',
      protocol: CoreNodeProtocol.http,
      server: '127.0.0.1',
      port: second,
    ),
  ],
  selectors: [],
  finalOutbound: 'A',
  rules: const [
    CoreRouteRule(kind: CoreRuleKind.always, value: '', outbound: 'A'),
  ],
);

void main() {
  test(
    'mode outbounds preserve subscription names and global default',
    () async {
      final profile = CoreProfileSpec(
        nodes: const [
          CoreNodeSpec(tag: 'Hotaru DIRECT', protocol: CoreNodeProtocol.direct),
          CoreNodeSpec(
            tag: 'Hotaru DIRECT (1)',
            protocol: CoreNodeProtocol.direct,
          ),
          CoreNodeSpec(tag: 'Hotaru GLOBAL', protocol: CoreNodeProtocol.direct),
        ],
        selectors: [],
        finalOutbound: 'Hotaru DIRECT',
      );
      final modes = CoreModeOutbounds(profile);
      expect(modes.direct.tag, 'Hotaru DIRECT (2)');
      expect(modes.global.tag, 'Hotaru GLOBAL (1)');
      expect(modes.global.members, profile.nodes.map((node) => node.tag));
      expect(modes.global.selected, profile.finalOutbound);
      final result = await SingBoxConfigBuilder().build(
        profile,
        const CoreListenerSpec(
          mixedPort: 17890,
          controllerPort: 19090,
          secret: 'fixture',
        ),
      );
      expect(result.issues, isEmpty);
      final config = jsonDecode(result.json!);
      expect(config['experimental']['clash_api']['default_mode'], 'rule');
      expect(config['route']['rules'], [
        {
          'clash_mode': 'direct',
          'action': 'route',
          'outbound': modes.direct.tag,
        },
        {
          'clash_mode': 'global',
          'action': 'route',
          'outbound': modes.global.tag,
        },
      ]);
    },
  );

  test(
    'offline preview respects each mode without resolving a domain',
    () async {
      final profile = _profile(8000, 8001);
      final modes = CoreModeOutbounds(profile);
      for (final mode in CoreRoutingMode.values) {
        final preview = await CoreRoutePreviewer().preview(
          profile,
          'example.invalid',
          mode: mode,
          selections: {modes.global.tag: 'B'},
        );
        expect(preview.status, CoreRoutePreviewStatus.resolved);
        expect(preview.chain, switch (mode) {
          CoreRoutingMode.rule => ['A'],
          CoreRoutingMode.global => [modes.global.tag, 'B'],
          CoreRoutingMode.direct => [modes.direct.tag],
        });
        expect(preview.ruleIndex, mode == CoreRoutingMode.rule ? 0 : null);
      }
    },
  );

  final binary = Platform.environment['HOTARU_TEST_SING_BOX'];
  final controlled = Platform.environment['HOTARU_TEST_SING_BOX_HOST'] == '1';
  test(
    'real engine mode changes alter the actual proxy receipt while explicit node probes stay pinned',
    () async {
      final directory = await Directory.systemTemp.createTemp('hotaru-modes-');
      addTearDown(() => directory.delete(recursive: true));
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => origin.close(force: true));
      final paths = <String>[];
      origin.listen((request) {
        paths.add(request.uri.path);
        request.response.write('mode-proof');
        unawaited(request.response.close());
      });
      final first = LoopbackProxyFixture(
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
        origin.port,
      );
      final second = LoopbackProxyFixture(
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
        origin.port,
      );
      addTearDown(first.close);
      addTearDown(second.close);
      final mixed = await freeLoopbackPort();
      final controller = await freeLoopbackPort();
      final probe = CoreProbeListenerSpec(
        port: await freeLoopbackPort(),
        secret: 'fixture-only-12345678901234567890123456789',
      );
      final profile = _profile(first.server.port, second.server.port);
      final modes = CoreModeOutbounds(profile);
      final built = await SingBoxConfigBuilder().build(
        profile,
        CoreListenerSpec(
          mixedPort: mixed,
          controllerPort: controller,
          secret: 'fixture',
          probe: probe,
        ),
      );
      expect(built.issues, isEmpty);
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
      final exitCode = process.exitCode.then((code) {
        exited = true;
        return code;
      });
      final output = <String>[];
      final readers = [
        process.stdout.transform(utf8.decoder).forEach(output.add),
        process.stderr.transform(utf8.decoder).forEach(output.add),
      ];
      addTearDown(() async {
        if (!exited) {
          if (controlled) {
            process.stdin.writeln('{"method":"stop"}');
            await process.stdin.flush();
          } else {
            process.kill();
          }
        }
        try {
          await exitCode.timeout(const Duration(seconds: 5));
        } on TimeoutException {
          process.kill(ProcessSignal.sigkill);
          await exitCode;
        }
        await Future.wait(readers);
      });
      final adapter = SingBoxClashApiAdapter(
        endpoint: Uri.parse('http://127.0.0.1:$controller'),
        secret: 'fixture',
        probe: probe,
        probeOutbounds: ['A', 'B'],
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
      await adapter.selectOutbound(modes.global.tag, 'B');
      Future<String> read(HttpClient client, String path) async {
        final request = await client.getUrl(
          Uri.parse('http://127.0.0.1:${origin.port}/$path'),
        );
        final response = await request.close();
        expect(response.statusCode, 200);
        return utf8.decoder.bind(response).join();
      }

      Future<String> mixedRequest(String path) async {
        final client = HttpClient()
          ..findProxy = (_) => 'PROXY 127.0.0.1:$mixed';
        try {
          return await read(client, path).timeout(const Duration(seconds: 5));
        } finally {
          client.close(force: true);
        }
      }

      expect(await adapter.routingMode(), CoreRoutingMode.rule);
      expect(await mixedRequest('rule'), 'mode-proof');
      expect(first.receipts, [origin.port]);
      expect(second.receipts, isEmpty);
      await adapter.setRoutingMode(CoreRoutingMode.global);
      expect(await mixedRequest('global'), 'mode-proof');
      expect(first.receipts, hasLength(1));
      expect(second.receipts, [origin.port]);
      await adapter.setRoutingMode(CoreRoutingMode.direct);
      expect(await mixedRequest('direct'), 'mode-proof');
      expect(first.receipts, hasLength(1));
      expect(second.receipts, hasLength(1));
      expect(
        await adapter.withOutboundClient(
          'A',
          (client) => read(client, 'pinned-in-direct'),
        ),
        'mode-proof',
      );
      expect(first.receipts, hasLength(2));
      expect(second.receipts, hasLength(1));
      expect(await adapter.routingMode(), CoreRoutingMode.direct);
      await adapter.setRoutingMode(CoreRoutingMode.rule);
      expect(await mixedRequest('rule-again'), 'mode-proof');
      expect(first.receipts, hasLength(3));
      expect(paths, [
        '/rule',
        '/global',
        '/direct',
        '/pinned-in-direct',
        '/rule-again',
      ]);
      expect(
        (await adapter.outbounds())
            .singleWhere((outbound) => outbound.name == modes.global.tag)
            .selected,
        'B',
      );
      stdout.writeln(
        jsonEncode({
          'proof': 'routing_modes',
          'rule_proxy': 'A',
          'global_proxy': 'B',
          'direct_bypassed_proxies': true,
          'probe_in_direct': 'A',
          'proxy_a_receipts': first.receipts.length,
          'proxy_b_receipts': second.receipts.length,
          'origin_paths': paths,
          'global_selection_preserved': true,
        }),
      );
    },
    skip: binary == null
        ? 'Set HOTARU_TEST_SING_BOX to a pinned real engine'
        : false,
  );
}
