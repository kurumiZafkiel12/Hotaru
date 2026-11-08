import 'dart:convert';
import 'dart:io';

import '../lib/core/adapter.dart';
import '../lib/core/config/profile.dart';
import '../lib/core/config/route_preview.dart';
import '../lib/core/sing_box/clash_api_adapter.dart';
import '../lib/core/sing_box/config_builder.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.contains('--build-protocol-config')) {
    const uuid = 'f0db417e-1460-4a2b-b37f-e62a1ab9d91c';
    final nodes = <CoreNodeSpec>[
      const CoreNodeSpec(tag: 'direct', protocol: CoreNodeProtocol.direct),
      for (final protocol in CoreNodeProtocol.values.where(
        (value) => value != CoreNodeProtocol.direct,
      ))
        CoreNodeSpec(
          tag: protocol.name,
          protocol: protocol,
          server: '127.0.0.1',
          port: 14443,
          password:
              const [
                CoreNodeProtocol.shadowsocks,
                CoreNodeProtocol.trojan,
                CoreNodeProtocol.hysteria2,
                CoreNodeProtocol.tuic,
              ].contains(protocol)
              ? 'fixture-password'
              : null,
          uuid:
              const [
                CoreNodeProtocol.vmess,
                CoreNodeProtocol.vless,
                CoreNodeProtocol.tuic,
              ].contains(protocol)
              ? uuid
              : null,
          cipher: protocol == CoreNodeProtocol.shadowsocks
              ? 'aes-128-gcm'
              : null,
          tls:
              const [
                CoreNodeProtocol.vless,
                CoreNodeProtocol.trojan,
                CoreNodeProtocol.hysteria2,
                CoreNodeProtocol.tuic,
              ].contains(protocol)
              ? CoreTlsSpec(serverName: 'localhost')
              : null,
          transport: protocol == CoreNodeProtocol.vmess
              ? CoreTransportSpec(
                  kind: CoreTransportKind.ws,
                  path: '/fixture',
                  headers: {'Host': 'localhost'},
                )
              : protocol == CoreNodeProtocol.vless
              ? CoreTransportSpec(
                  kind: CoreTransportKind.grpc,
                  serviceName: 'fixture',
                )
              : null,
        ),
      CoreNodeSpec(
        tag: 'reality',
        protocol: CoreNodeProtocol.vless,
        server: '127.0.0.1',
        port: 14443,
        uuid: uuid,
        flow: 'xtls-rprx-vision',
        tls: CoreTlsSpec(
          serverName: 'localhost',
          fingerprint: 'chrome',
          realityPublicKey: base64Url
              .encode(List.generate(32, (index) => index + 1))
              .replaceAll('=', ''),
          realityShortId: '01234567',
        ),
      ),
    ];
    final result = await SingBoxConfigBuilder().build(
      CoreProfileSpec(
        nodes: nodes,
        selectors: [
          CoreSelectorSpec(
            tag: 'automatic',
            members: ['http', 'socks'],
            strategy: CoreGroupStrategy.urltest,
          ),
        ],
        finalOutbound: 'direct',
        rules: [
          const CoreRouteRule(
            kind: CoreRuleKind.domainSuffix,
            value: 'example.com',
            outbound: 'automatic',
          ),
          const CoreRouteRule(
            kind: CoreRuleKind.ipCidr,
            noResolve: true,
            value: '192.0.2.0/24',
            outbound: 'direct',
          ),
        ],
      ),
      const CoreListenerSpec(
        mixedPort: 17890,
        controllerPort: 19090,
        secret: 'fixture-secret',
      ),
    );
    if (result.json == null) {
      throw StateError('Protocol fixture compilation failed');
    }
    stdout.writeln(result.json);
    return;
  }
  if (arguments.contains('--build-config')) {
    final input =
        jsonDecode(await utf8.decoder.bind(stdin).join())
            as Map<String, dynamic>;
    final profile = _fixtureProfile(input);
    final result = await SingBoxConfigBuilder().build(
      profile,
      CoreListenerSpec(
        mixedPort: input['mixedPort'] as int,
        controllerPort: input['controllerPort'] as int,
        secret: input['secret'] as String,
        tun: input['tunName'] == null
            ? null
            : CoreTunSpec(
                interfaceName: input['tunName'] as String,
                addresses: ['198.18.7.1/30'],
                autoRoute: false,
              ),
      ),
    );
    if (result.json == null) {
      throw StateError('Fixture configuration is invalid');
    }
    stdout.writeln(result.json);
    return;
  }
  final adapter = SingBoxClashApiAdapter(
    endpoint: Uri.parse(Platform.environment['HOTARU_PROBE_API']!),
    secret: Platform.environment['HOTARU_PROBE_SECRET']!,
  );
  try {
    final nodes = await adapter.outbounds();
    if (!nodes.any((node) => node.name == 'node-a')) {
      throw StateError('Missing controlled outbound');
    }
    final snapshot = await adapter.connections();
    final active = snapshot.entries.where(
      (entry) => entry.chain.contains('node-b'),
    );
    if (active.length != 1 || active.single.download == 0) {
      throw StateError('Active route or transfer counter mismatch');
    }
    await adapter.selectOutbound('selected', 'node-a');
    final delay = await adapter.delay(
      'node-b',
      Uri.parse(Platform.environment['HOTARU_PROBE_TARGET']!),
      const Duration(seconds: 3),
    );
    final selection = (await adapter.outbounds()).singleWhere(
      (node) => node.name == 'selected',
    );
    if (selection.selected != 'node-a') {
      throw StateError('Node-specific delay changed the selected route');
    }
    final preview = await CoreRoutePreviewer().preview(
      _fixtureProfile(
        jsonDecode(Platform.environment['HOTARU_PROBE_PROFILE']!)
            as Map<String, dynamic>,
      ),
      'offline-preview.invalid',
      selections: {'selected': selection.selected!},
    );
    if (preview.status != CoreRoutePreviewStatus.resolved ||
        preview.ruleIndex != null ||
        preview.chain.join('>') != 'selected>node-a') {
      throw StateError('Offline preview differs from the live selection');
    }
    await adapter.closeConnection(active.single.id);
    if ((await adapter.connections()).entries.any(
      (entry) => entry.id == active.single.id,
    )) {
      throw StateError('Connection was not closed');
    }
    stdout.writeln(
      jsonEncode({'adapter': 'passed', 'delayMs': delay.inMilliseconds}),
    );
  } on CoreAdapterException catch (error) {
    stderr.writeln(error);
    exitCode = 1;
  } finally {
    await adapter.close();
  }
}

CoreProfileSpec _fixtureProfile(Map<String, dynamic> input) => CoreProfileSpec(
  nodes: [
    for (final node in input['nodes'] as List)
      CoreNodeSpec(
        tag: node['tag'] as String,
        protocol: CoreNodeProtocol.http,
        server: '127.0.0.1',
        port: node['port'] as int,
      ),
  ],
  selectors: [
    CoreSelectorSpec(tag: 'selected', members: ['node-a', 'node-b']),
  ],
  finalOutbound: 'selected',
);
// The Windows protocol job runs directly with the standalone Dart SDK.
// ignore_for_file: avoid_relative_lib_imports
