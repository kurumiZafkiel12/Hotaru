import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/config/clash_importer.dart';
import 'package:hotaru/core/config/dns.dart';
import 'package:hotaru/core/config/profile.dart';
import 'package:hotaru/core/config/route_preview.dart';
import 'package:hotaru/core/sing_box/clash_api_adapter.dart';
import 'package:hotaru/core/sing_box/config_builder.dart';

import 'loopback_proxy_fixture.dart';

const _listeners = CoreListenerSpec(
  mixedPort: 17890,
  controllerPort: 19090,
  secret: 'detour-fixture',
);

CoreProfileSpec _profile({
  String? detour = 'relay',
  List<CoreSelectorSpec> selectors = const [],
  CoreDnsSpec? dns,
}) => CoreProfileSpec(
  nodes: [
    const CoreNodeSpec(
      tag: 'relay',
      protocol: CoreNodeProtocol.http,
      server: '127.0.0.1',
      port: 8081,
    ),
    CoreNodeSpec(
      tag: 'exit',
      protocol: CoreNodeProtocol.http,
      server: '127.0.0.1',
      port: 8082,
      detour: detour,
    ),
  ],
  selectors: selectors,
  finalOutbound: 'exit',
  dns: dns,
);

void main() {
  test(
    'Clash dialer-proxy is retained in IR and compiled to native detour',
    () async {
      final result = await ClashProfileImporter().import(
        jsonEncode({
          'proxies': [
            {
              'name': 'relay',
              'type': 'http',
              'server': '127.0.0.1',
              'port': 8081,
            },
            {
              'name': 'exit',
              'type': 'http',
              'server': '127.0.0.1',
              'port': 8082,
              'dialer-proxy': 'relay',
            },
          ],
          'rules': ['MATCH,exit'],
        }),
      );
      expect(result.issues, isEmpty);
      expect(
        result.profile!.nodes.singleWhere((node) => node.tag == 'exit').detour,
        'relay',
      );
      final built = await SingBoxConfigBuilder().build(
        result.profile!,
        _listeners,
      );
      expect(built.issues, isEmpty);
      final outbounds = jsonDecode(built.json!)['outbounds'] as List;
      expect(
        outbounds.singleWhere((node) => node['tag'] == 'exit')['detour'],
        'relay',
      );
    },
  );

  test(
    'missing detour and cycles through nodes/selectors cannot activate',
    () async {
      final missing = await SingBoxConfigBuilder().build(
        _profile(detour: 'missing'),
        _listeners,
      );
      expect(missing.json, isNull);
      expect(
        missing.issues.any((issue) => issue.code == 'unknown_detour'),
        isTrue,
      );
      for (final profile in [
        _profile(detour: 'exit'),
        _profile(
          detour: 'group',
          selectors: [
            CoreSelectorSpec(tag: 'group', members: ['exit', 'relay']),
          ],
        ),
        CoreProfileSpec(
          nodes: const [
            CoreNodeSpec(
              tag: 'direct',
              protocol: CoreNodeProtocol.direct,
              detour: 'direct',
            ),
          ],
          selectors: [],
          finalOutbound: 'direct',
        ),
      ]) {
        final built = await SingBoxConfigBuilder().build(profile, _listeners);
        expect(built.json, isNull);
        expect(
          built.issues.any((issue) => issue.code == 'outbound_cycle'),
          isTrue,
        );
      }
    },
  );

  test(
    'empty direct detour is rejected before the native engine rejects it',
    () async {
      final profile = CoreProfileSpec(
        nodes: const [
          CoreNodeSpec(tag: 'direct', protocol: CoreNodeProtocol.direct),
          CoreNodeSpec(
            tag: 'proxy',
            protocol: CoreNodeProtocol.http,
            server: '127.0.0.1',
            port: 8080,
            detour: 'direct',
          ),
        ],
        selectors: [],
        finalOutbound: 'proxy',
      );
      final built = await SingBoxConfigBuilder().build(profile, _listeners);
      expect(built.json, isNull);
      expect(built.issues.single.code, 'empty_direct_detour');
    },
  );

  test(
    'remote hostname resolution through a detour does not invent a local DNS cycle',
    () async {
      CoreProfileSpec profile({String? resolver}) => CoreProfileSpec(
        nodes: const [
          CoreNodeSpec(
            tag: 'relay',
            protocol: CoreNodeProtocol.http,
            server: '127.0.0.1',
            port: 8080,
          ),
          CoreNodeSpec(
            tag: 'exit',
            protocol: CoreNodeProtocol.http,
            server: 'exit.invalid',
            port: 8081,
            detour: 'relay',
          ),
        ],
        selectors: [],
        finalOutbound: 'exit',
        dns: CoreDnsSpec(
          servers: const [
            CoreDnsServerSpec(
              tag: 'upstream',
              protocol: CoreDnsProtocol.tcp,
              server: '192.0.2.53',
              port: 53,
              detour: 'exit',
            ),
          ],
          finalServer: 'upstream',
          proxyServer: resolver,
        ),
      );
      expect(
        (await SingBoxConfigBuilder().build(profile(), _listeners)).issues,
        isEmpty,
      );
      final recursive = await SingBoxConfigBuilder().build(
        profile(resolver: 'upstream'),
        _listeners,
      );
      expect(recursive.json, isNull);
      expect(
        recursive.issues.any((issue) => issue.code == 'dns_dependency_cycle'),
        isTrue,
      );
    },
  );

  test(
    'detour DNS dependencies participate in the same recursion check',
    () async {
      final dns = CoreDnsSpec(
        servers: const [
          CoreDnsServerSpec(
            tag: 'dns',
            protocol: CoreDnsProtocol.udp,
            server: '192.0.2.53',
            port: 53,
            detour: 'exit',
          ),
        ],
        finalServer: 'dns',
        proxyServer: 'dns',
      );
      final profile = CoreProfileSpec(
        nodes: const [
          CoreNodeSpec(
            tag: 'relay',
            protocol: CoreNodeProtocol.http,
            server: 'relay.invalid',
            port: 8081,
          ),
          CoreNodeSpec(
            tag: 'exit',
            protocol: CoreNodeProtocol.http,
            server: '127.0.0.1',
            port: 8082,
            detour: 'relay',
          ),
        ],
        selectors: [],
        finalOutbound: 'exit',
        dns: dns,
      );
      final built = await SingBoxConfigBuilder().build(profile, _listeners);
      expect(built.json, isNull);
      expect(
        built.issues.any((issue) => issue.code == 'dns_dependency_cycle'),
        isTrue,
      );
    },
  );

  test(
    'preview distinguishes policy chain and physical entry-to-exit hops',
    () async {
      final profile = _profile(
        detour: 'relay-group',
        selectors: [
          CoreSelectorSpec(tag: 'relay-group', members: ['relay']),
        ],
      );
      final previewer = CoreRoutePreviewer();
      final unresolved = await previewer.preview(profile, 'example.org');
      expect(unresolved.status, CoreRoutePreviewStatus.selectionRequired);
      expect(unresolved.hops, isEmpty);
      final result = await previewer.preview(
        profile,
        'example.org',
        selections: {'relay-group': 'relay'},
      );
      expect(result.status, CoreRoutePreviewStatus.resolved);
      expect(result.chain, ['exit']);
      expect(result.hops, ['relay', 'exit']);
      expect(result.selectedOutbounds, {'relay-group': 'relay'});
      expect(() => result.hops.clear(), throwsUnsupportedError);
      expect(() => result.selectedOutbounds.clear(), throwsUnsupportedError);
    },
  );

  final binary = Platform.environment['HOTARU_TEST_SING_BOX'];
  final controlledHost =
      Platform.environment['HOTARU_TEST_SING_BOX_HOST'] == '1';
  test(
    'real engine reaches exit through relay, proven by independent CONNECT receipts',
    () async {
      final directory = await Directory.systemTemp.createTemp('hotaru-detour-');
      addTearDown(() => directory.delete(recursive: true));
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => origin.close(force: true));
      final release = Completer<void>();
      final originSeen = Completer<void>();
      final exit = LoopbackProxyFixture(
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
        origin.port,
      );
      addTearDown(exit.close);
      final relay = LoopbackProxyFixture(
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
        exit.server.port,
      );
      addTearDown(relay.close);
      Process? process;
      Future<int>? exitCode;
      var exited = false;
      final readers = <Future<void>>[];
      final output = <String>[];
      SingBoxClashApiAdapter? api;
      HttpClient? client;
      var originRequests = 0;
      origin.listen((request) async {
        try {
          originRequests++;
          request.response.contentLength = 12;
          request.response.write('detour');
          await request.response.flush();
          if (!originSeen.isCompleted) originSeen.complete();
          await release.future;
          request.response.write('-proof');
          await request.response.close();
        } catch (_) {}
      });
      try {
        final mixed = await freeLoopbackPort();
        final controller = await freeLoopbackPort();
        final imported = await ClashProfileImporter().import(
          jsonEncode({
            'proxies': [
              {
                'name': 'relay',
                'type': 'http',
                'server': '127.0.0.1',
                'port': relay.server.port,
              },
              {
                'name': 'exit',
                'type': 'http',
                'server': '127.0.0.1',
                'port': exit.server.port,
                'dialer-proxy': 'relay',
              },
            ],
            'proxy-groups': [
              {
                'name': 'selected',
                'type': 'select',
                'proxies': ['exit'],
              },
            ],
            'rules': ['MATCH,selected'],
          }),
        );
        expect(imported.issues, isEmpty);
        final built = await SingBoxConfigBuilder().build(
          imported.profile!,
          CoreListenerSpec(
            mixedPort: mixed,
            controllerPort: controller,
            secret: 'detour-fixture',
          ),
        );
        expect(built.issues, isEmpty);
        final file = File('${directory.path}/config.json');
        await file.writeAsString(built.json!);
        process = await Process.start(binary!, [
          'run',
          '-c',
          file.path,
          if (controlledHost) '--stdio-control',
        ]);
        exitCode = process.exitCode.then((code) {
          exited = true;
          return code;
        });
        readers.add(process.stdout.transform(utf8.decoder).forEach(output.add));
        readers.add(process.stderr.transform(utf8.decoder).forEach(output.add));
        api = SingBoxClashApiAdapter(
          endpoint: Uri.parse('http://127.0.0.1:$controller'),
          secret: 'detour-fixture',
        );
        var ready = false;
        for (var attempt = 0; attempt < 100; attempt++) {
          try {
            await api.version();
            ready = true;
            break;
          } catch (_) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        }
        expect(ready, isTrue, reason: output.join());
        client = HttpClient()..findProxy = (_) => 'PROXY 127.0.0.1:$mixed';
        final request = await client.getUrl(
          Uri.parse('http://127.0.0.1:${origin.port}/proof'),
        );
        final response = await request.close().timeout(
          const Duration(seconds: 5),
        );
        await originSeen.future.timeout(const Duration(seconds: 5));
        final snapshot = await api.connections();
        expect(snapshot.entries, hasLength(1));
        expect(snapshot.entries.single.chain, contains('exit'));
        expect(relay.receipts, [exit.server.port]);
        expect(exit.receipts, [origin.port]);
        expect(originRequests, 1);
        final preview = await CoreRoutePreviewer().preview(
          imported.profile!,
          '127.0.0.1',
          selections: {'selected': 'exit'},
        );
        expect(preview.hops, ['relay', 'exit']);
        stdout.writeln(
          jsonEncode({
            'scope':
                'Owned loopback engine and two independent proxies; no OS proxy or TUN changes',
            'controlled_host': controlledHost,
            'relay_connect_targets': relay.receipts,
            'exit_connect_targets': exit.receipts,
            'observed_core_chain': snapshot.entries.single.chain,
            'physical_hops': preview.hops,
          }),
        );
        release.complete();
        expect(await utf8.decoder.bind(response).join(), 'detour-proof');
      } finally {
        if (!release.isCompleted) release.complete();
        client?.close(force: true);
        await api?.close();
        if (process != null) {
          try {
            if (controlledHost) {
              process.stdin.writeln('stop');
              await process.stdin.flush();
              await process.stdin.close();
            } else {
              process.kill(ProcessSignal.sigterm);
            }
            final code = await exitCode!.timeout(
              const Duration(seconds: 5),
              onTimeout: () {
                process!.kill(ProcessSignal.sigterm);
                return exitCode!.timeout(const Duration(seconds: 5));
              },
            );
            await Future.wait(readers);
            if (controlledHost) {
              expect(code, 0);
              final events = const LineSplitter()
                  .convert(output.join())
                  .where((line) => line.startsWith('{'))
                  .map(jsonDecode)
                  .toList();
              expect(events.last['event'], 'stopped');
              expect(events.last['clean'], isTrue);
            }
          } finally {
            if (!exited) {
              process.kill(ProcessSignal.sigterm);
              await exitCode!.timeout(const Duration(seconds: 5));
            }
          }
        }
      }
    },
    skip: binary == null
        ? 'Set HOTARU_TEST_SING_BOX to the verified pinned engine'
        : false,
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
