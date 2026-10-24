import 'dart:io';

import 'package:hotaru/core/mihomo_controller.dart';

Future<void> main(List<String> args) async {
  if (Platform.environment['GITHUB_ACTIONS'] != 'true') {
    throw StateError('Isolated CI only');
  }
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    request.response.write('service-proxy-ok');
    await request.response.close();
  });
  final dir = await Directory.systemTemp.createTemp('hotaru-service-smoke-');
  final core = MihomoController()
    ..serviceMode = true
    ..serviceExecutable = File(args[1]).absolute.path;
  final client = HttpClient();
  try {
    final port = await MihomoController.findFreePort();
    await core.startRuntime(
      File(args[0]).absolute.path,
      dir,
      runtimeConfig: {
        'mode': 'direct',
        'rules': ['MATCH,DIRECT'],
      },
      mixedPort: port,
    );
    client.findProxy = (_) => 'PROXY 127.0.0.1:$port';
    final response = await (await client.getUrl(
      Uri.parse('http://127.0.0.1:${server.port}/'),
    )).close();
    final body = await response
        .transform(const SystemEncoding().decoder)
        .join();
    if (body != 'service-proxy-ok') {
      throw StateError('Service core did not proxy request');
    }
    await core.stop();
    var released = false;
    for (var i = 0; i < 100; i++) {
      try {
        final socket = await Socket.connect(
          '127.0.0.1',
          port,
          timeout: const Duration(milliseconds: 100),
        );
        socket.destroy();
      } catch (_) {
        released = true;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (!released) throw StateError('Service lease did not stop the core');
    stdout.writeln(
      'PASS SCM LocalService core API, real HTTP proxy and lease cleanup',
    );
  } finally {
    await core.dispose();
    client.close(force: true);
    await server.close(force: true);
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}
