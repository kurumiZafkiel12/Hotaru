// This privileged packet probe is restricted to disposable Windows CI.
// ignore_for_file: avoid_relative_lib_imports

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../lib/core/desktop/model.dart';
import '../lib/core/sing_box/desktop_core.dart';

Future<void> main() async {
  if (!Platform.isWindows || Platform.environment['CI'] != 'true') {
    throw StateError('TUN probe is restricted to disposable Windows CI');
  }
  final environment = Platform.environment;
  final target = Uri.parse(environment['HOTARU_PROBE_TUN_TARGET']!);
  final endpoint = Uri.parse(environment['HOTARU_PROBE_API']!);
  final context = SecurityContext(withTrustedRoots: false)
    ..setTrustedCertificates(environment['HOTARU_PROBE_CA']!);
  final client = HttpClient(context: context)
    ..connectionTimeout = const Duration(seconds: 5)
    ..findProxy = (_) => 'DIRECT';
  final core = SingBoxDesktopCore(
    executable: environment['HOTARU_PROBE_BINARY']!,
    configPath: environment['HOTARU_PROBE_CONFIG']!,
    endpoint: endpoint,
    secret: environment['HOTARU_PROBE_SECRET']!,
    stdioControl: true,
    onStderr: stderr.write,
  );
  StreamSubscription<List<int>>? body;
  try {
    final unsupported = SingBoxDesktopCore(
      executable: environment['HOTARU_PROBE_BINARY']!,
      configPath: environment['HOTARU_PROBE_CONFIG']!,
      endpoint: endpoint,
      secret: environment['HOTARU_PROBE_SECRET']!,
    );
    try {
      var rejected = false;
      try {
        await unsupported.start();
      } on DesktopCoreFailure catch (error) {
        rejected = error.cause.toString().contains(
          'requires the graceful desktop host',
        );
      }
      if (!rejected) {
        throw StateError('Ungraceful Windows TUN launch was not rejected');
      }
    } finally {
      await unsupported.close();
    }
    final started = await core.start();
    final request = await client.getUrl(target.replace(path: '/hold'));
    request.persistentConnection = false;
    final response = await request.close().timeout(const Duration(seconds: 5));
    if (response.statusCode != 200) {
      throw StateError('TUN HTTPS request failed');
    }
    final firstByte = Completer<void>();
    final completed = Completer<void>();
    firstByte.future.ignore();
    completed.future.ignore();
    body = response.listen(
      (bytes) {
        if (bytes.isNotEmpty && !firstByte.isCompleted) firstByte.complete();
      },
      onDone: () {
        if (!completed.isCompleted) completed.complete();
      },
      onError: (Object error, StackTrace trace) {
        if (!firstByte.isCompleted) firstByte.completeError(error, trace);
        if (!completed.isCompleted) completed.completeError(error, trace);
      },
      cancelOnError: true,
    );
    await firstByte.future.timeout(const Duration(seconds: 5));
    final connections = await core.adapter.connections();
    final captured = connections.entries
        .where(
          (entry) =>
              entry.destinationIp == target.host &&
              entry.destinationPort == '${target.port}' &&
              entry.inbound == 'tun/tun' &&
              entry.chain.contains('node-a'),
        )
        .toList();
    if (captured.length != 1 ||
        captured.single.download == 0 ||
        captured.single.upload == 0) {
      throw StateError(
        'Request did not traverse the expected TUN and selected node',
      );
    }
    final control = await client.getUrl(
      target.replace(host: '127.0.0.1', path: '/release'),
    );
    final released = await control.close();
    await released.drain<void>();
    await completed.future.timeout(const Duration(seconds: 5));
    await core.adapter.selectOutbound('selected', 'node-b');
    final second = await client.getUrl(target.replace(path: '/receipt'));
    second.persistentConnection = false;
    final secondResponse = await second.close().timeout(
      const Duration(seconds: 5),
    );
    final content = await utf8.decoder.bind(secondResponse).join();
    if (secondResponse.statusCode != 200 ||
        content != 'hotaru-sing-box-probe') {
      throw StateError('Second selected-node TUN request failed');
    }
    client.close(force: true);
    await core.stop();
    final exitCode =
        await (started.session!.lease as CoreProcessExitSource).exitCode;
    if (exitCode != 0 || core.lifecycle.state is! DesktopCoreIdle) {
      throw StateError('TUN host did not exit normally');
    }
    stdout.writeln(
      jsonEncode({
        'tunPacketPath': 'passed',
        'processPathAvailable': captured.single.processPath != null,
        'gracefulExitCode': exitCode,
      }),
    );
  } finally {
    await body?.cancel();
    client.close(force: true);
    await core.close();
  }
}
