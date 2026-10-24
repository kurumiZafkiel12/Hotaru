import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hotaru/core/mihomo_controller.dart';
import 'package:hotaru/core/proxy_config.dart';
import 'package:hotaru/profiles/importer.dart';

/// End-to-end proxy-loop smoke with a real Mihomo binary, fully local:
///
///   this tool --(HTTP via mixed port)--> main Mihomo (Hotaru controller)
///     --(node: socks5)--> upstream Mihomo listener --(DIRECT)--> target HTTP
///
/// Proof of proxying is threefold: the target only gets the request while
/// a /connections snapshot on the main core shows the chain through the
/// selected node; the core's own delay probe succeeds through the node;
/// and after the core stops, the same request through the port fails.
///
/// Usage: dart run tool/proxy_loop_smoke.dart `mihomo-executable-path`
Future<void> main(List<String> args) async {
  if (args.length != 1) {
    throw ArgumentError('Pass absolute Mihomo executable path');
  }
  final exe = args.single;
  final dir = await Directory.systemTemp.createTemp('hotaru-loop-');
  final core = MihomoController();
  Process? upstream;
  HttpServer? target;
  final slowArrived = Completer<void>();
  final releaseSlow = Completer<void>();
  try {
    // 1) Target HTTP server (the "website").
    target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final targetPort = target.port;
    unawaited(
      target.forEach((request) async {
        if (request.uri.path == '/slow') {
          if (!slowArrived.isCompleted) slowArrived.complete();
          await releaseSlow.future;
        }
        request.response.write('hotaru-proxy-ok');
        await request.response.close();
      }),
    );

    // 2) Upstream Mihomo exposing a SOCKS listener = our "node".
    final upCtrl = await MihomoController.findFreePort();
    final upSocks = await MihomoController.findFreePort();
    const upSecret = 'smoke-upstream-secret-0123456789abcdef';
    final upDir = Directory('${dir.path}/upstream')..createSync();
    final upConfig = File('${upDir.path}/up.json');
    await upConfig.writeAsString(
      jsonEncode({
        'mixed-port': 0,
        'allow-lan': false,
        'external-controller': '127.0.0.1:$upCtrl',
        'secret': upSecret,
        'mode': 'rule',
        'log-level': 'warning',
        'ipv6': false,
        'tun': {'enable': false},
        'dns': {'enable': false},
        'listeners': [
          {
            'name': 'up-in',
            'type': 'socks',
            'listen': '127.0.0.1',
            'port': upSocks,
            'udp': true,
          },
        ],
        'rules': ['MATCH,DIRECT'],
      }),
    );
    upstream = await Process.start(exe, [
      '-d',
      upDir.path,
      '-f',
      upConfig.path,
    ]);
    unawaited(upstream.stdout.drain<void>());
    unawaited(upstream.stderr.drain<void>());
    await _waitVersion(upCtrl, upSecret);
    stdout.writeln('upstream listener ready: socks 127.0.0.1:$upSocks');

    // 3) Import the node exactly like a user would, build runtime config,
    //    and start it through the real controller.
    final parsed = ProfileImporter.parse(
      'socks5://127.0.0.1:$upSocks#upstream-node',
      ImportMode.nodesOnly,
    );
    final mixed = await MihomoController.findFreePort();
    final runtime = ProxyConfigBuilder.build(
      profileConfig: parsed.config,
      mode: ImportMode.nodesOnly,
      selectedNode: 'upstream-node',
    );
    await core.startRuntime(
      exe,
      Directory('${dir.path}/main'),
      runtimeConfig: runtime,
      mixedPort: mixed,
    );
    if (core.status != CoreStatus.running) throw StateError('core not running');
    final group = await core.api!.selectNode('upstream-node');
    if (group != ProxyConfigBuilder.selectGroup) {
      throw StateError('selectNode returned $group');
    }
    stdout.writeln(
      'main core running: mixed 127.0.0.1:$mixed, mihomo ${core.coreVersion}',
    );

    // 4) Core-side latency probe through the node to the target.
    final delay = await core.api!.delay(
      'upstream-node',
      url: 'http://127.0.0.1:$targetPort/',
    );
    if (delay == null) throw StateError('delay probe through node failed');
    stdout.writeln('delay through node: $delay ms');

    // 5) Real HTTP request through the mixed port, with a /connections
    //    snapshot taken mid-flight as chain evidence.
    final client = HttpClient()..findProxy = (_) => 'PROXY 127.0.0.1:$mixed';
    final slowFuture = client
        .getUrl(Uri.parse('http://127.0.0.1:$targetPort/slow'))
        .then((r) => r.close())
        .then((r) => r.transform(utf8.decoder).join());
    unawaited(
      slowFuture.catchError((Object error, StackTrace stack) {
        if (!slowArrived.isCompleted) slowArrived.completeError(error, stack);
        return '';
      }),
    );
    await slowArrived.future.timeout(const Duration(seconds: 10));
    final snapshot = await core.api!.connections();
    final connections = snapshot['connections'];
    if (connections is! List || connections.isEmpty) {
      throw StateError('no live connection visible on the core');
    }
    final chains = connections
        .map((c) => (c as Map)['chains'])
        .expand((c) => c as List)
        .toList();
    if (!chains.contains('upstream-node')) {
      throw StateError('connection chain lacks upstream-node: $chains');
    }
    releaseSlow.complete();
    final body = await slowFuture.timeout(const Duration(seconds: 10));
    if (body != 'hotaru-proxy-ok') throw StateError('unexpected body: $body');
    client.close(force: true);
    stdout.writeln('proxied request ok; chain evidence: $chains');

    // 6) After stop, the same proxied request must fail (no fake success).
    await core.stop();
    var failedAfterStop = false;
    final client2 = HttpClient();
    client2.findProxy = (_) => 'PROXY 127.0.0.1:$mixed';
    client2.connectionTimeout = const Duration(seconds: 2);
    try {
      final req = await client2
          .getUrl(Uri.parse('http://127.0.0.1:$targetPort/'))
          .timeout(const Duration(seconds: 3));
      await req.close().timeout(const Duration(seconds: 3));
    } catch (_) {
      failedAfterStop = true;
    } finally {
      client2.close(force: true);
    }
    if (!failedAfterStop) throw StateError('request still worked after stop');
    stdout.writeln(
      'PASS: import -> build -> start -> select -> delay -> proxied HTTP '
      '(chain verified) -> stop (port closed)',
    );
  } finally {
    if (!releaseSlow.isCompleted) releaseSlow.complete();
    await core.dispose();
    upstream?.kill();
    if (upstream != null) {
      await upstream.exitCode.timeout(const Duration(seconds: 5));
    }
    await target?.close(force: true);
    for (var attempt = 0; attempt < 10; attempt++) {
      try {
        await dir.delete(recursive: true);
        break;
      } on FileSystemException {
        if (attempt == 9) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  }
}

Future<void> _waitVersion(int port, String secret) async {
  final http = HttpClient()..connectionTimeout = const Duration(seconds: 1);
  try {
    for (var i = 0; i < 40; i++) {
      try {
        final req = await http.getUrl(
          Uri.parse('http://127.0.0.1:$port/version'),
        );
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $secret');
        final res = await req.close();
        await res.drain<void>();
        if (res.statusCode == 200) return;
      } catch (_) {
        /* retry */
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    throw StateError('upstream core did not become healthy');
  } finally {
    http.close(force: true);
  }
}
