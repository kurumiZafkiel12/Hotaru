import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hotaru/core/mihomo_controller.dart';
import 'package:hotaru/core/proxy_config.dart';
import 'package:hotaru/profiles/importer.dart';

Future<void> main(List<String> args) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final dir = await Directory.systemTemp.createTemp('hotaru-providers-');
  final core = MihomoController();
  var generation = 1;
  final origin = 'http://127.0.0.1:${server.port}';
  server.listen((request) async {
    switch (request.uri.path) {
      case '/nodes':
        request.response.write(
          'proxies:\n  - {name: provider-$generation, type: direct}\n',
        );
      case '/rules':
        request.response.write('payload:\n  - DOMAIN,example.test\n');
      default:
        request.response.statusCode = 204;
    }
    await request.response.close();
  });
  try {
    final source = jsonEncode({
      'proxy-providers': {
        'remote': {'type': 'http', 'url': '$origin/nodes', 'interval': 3600},
      },
      'proxy-groups': [
        for (final type in ['select', 'url-test', 'fallback', 'load-balance'])
          {
            'name': type,
            'type': type,
            'use': ['remote'],
            'url': '$origin/probe',
            'interval': 300,
          },
      ],
      'rule-providers': {
        'sample': {
          'type': 'http',
          'behavior': 'classical',
          'url': '$origin/rules',
          'interval': 3600,
        },
      },
      'rules': ['RULE-SET,sample,DIRECT', 'MATCH,select'],
    });
    final parsed = ProfileImporter.parse(source, ImportMode.fullConfig);
    await core.startRuntime(
      File(args.first).absolute.path,
      dir,
      runtimeConfig: ProxyConfigBuilder.build(
        profileConfig: parsed.config,
        mode: ImportMode.fullConfig,
        selectedNode: '',
      ),
      mixedPort: await MihomoController.findFreePort(),
    );
    final api = core.api!;
    Future<void> contains(String node) async {
      for (var i = 0; i < 100; i++) {
        if (((await api.getMap(
                  '/providers/proxies',
                ))['providers']['remote']['proxies']
                as List)
            .any((p) => p['name'] == node)) {
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      throw StateError('Provider node absent: $node');
    }

    await contains('provider-1');
    for (final type in ['Selector', 'URLTest', 'Fallback', 'LoadBalance']) {
      if (!(await api.proxies()).values.any((p) => p['type'] == type)) {
        throw StateError('Group missing: $type');
      }
    }
    await api.select('select', 'provider-1');
    if (await api.delay(
          'provider-1',
          provider: 'remote',
          url: '$origin/probe',
        ) ==
        null) {
      throw StateError('True delay failed');
    }
    for (final mode in ['global', 'direct', 'rule']) {
      await api.setMode(mode);
      if ((await api.getMap('/configs'))['mode'] != mode) {
        throw StateError('Mode not applied');
      }
    }
    await api.events('/traffic').first.timeout(const Duration(seconds: 5));
    await api.connections();
    final rules = await api.getMap('/providers/rules');
    if (!(rules['providers'] as Map).containsKey('sample')) {
      throw StateError('Rules provider missing');
    }
    generation = 2;
    await api.updateProvider('remote');
    await contains('provider-2');
    await api.updateProvider('sample', rules: true);
    stdout.writeln(
      'PASS provider-only, all four groups, true delay, selection, three modes, traffic WS, connections, provider updates',
    );
  } finally {
    await core.dispose();
    await server.close(force: true);
    for (var i = 0; i < 20; i++) {
      try {
        await dir.delete(recursive: true);
        break;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  }
}
