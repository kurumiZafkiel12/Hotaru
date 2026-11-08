import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/config/profile.dart';
import 'package:hotaru/core/config/runtime_options.dart';
import 'package:hotaru/core/routed_http.dart';
import 'package:hotaru/core/sing_box/config_builder.dart';
import 'package:hotaru/core/sing_box/http_probe.dart';
import 'package:hotaru/core/telemetry.dart';
import 'package:hotaru/models/core.dart';

import 'loopback_proxy_fixture.dart';

class _Mixed implements CoreRoutedHttp {
  final int port;
  _Mixed(this.port);
  @override
  Future<T> withRoutedClient<T>(
    Future<T> Function(HttpClient) action, {
    String? outbound,
    Duration timeout = const Duration(minutes: 2),
  }) async {
    if (outbound != null) {
      throw StateError('Only the ordinary route is under test');
    }
    final client = HttpClient()..findProxy = (_) => 'PROXY 127.0.0.1:$port';
    try {
      return await action(client).timeout(timeout);
    } finally {
      client.close(force: true);
    }
  }
}

void main() {
  final binary = Platform.environment['HOTARU_TEST_SING_BOX'];
  final enabled =
      binary != null &&
      Platform.environment['HOTARU_TEST_SING_BOX_HOST'] == '1';
  test(
    'real host correlates probe sockets with the actual B route and independent receipts',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'hotaru-probe-observation-',
      );
      addTearDown(() => directory.delete(recursive: true));
      var origins = 0;
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => origin.close(force: true));
      origin.listen((request) {
        origins++;
        request.response.write('independent-probe-receipt');
        unawaited(request.response.close());
      });
      final a = LoopbackProxyFixture(
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
        origin.port,
      );
      final b = LoopbackProxyFixture(
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
        origin.port,
      );
      addTearDown(a.close);
      addTearDown(b.close);
      final mixed = await freeLoopbackPort();
      final controller = await freeLoopbackPort();
      final built = await SingBoxConfigBuilder().build(
        CoreProfileSpec(
          nodes: [
            for (final (name, port) in [
              ('A', a.server.port),
              ('B', b.server.port),
            ])
              CoreNodeSpec(
                tag: name,
                protocol: CoreNodeProtocol.http,
                server: '127.0.0.1',
                port: port,
              ),
          ],
          selectors: [
            CoreSelectorSpec(
              tag: 'Selected',
              members: ['A', 'B'],
              selected: 'B',
            ),
          ],
          finalOutbound: 'Selected',
          runtime: const CoreRuntimeOptions(findProcess: true),
        ),
        CoreListenerSpec(
          mixedPort: mixed,
          controllerPort: controller,
          secret: 'fixture',
        ),
      );
      expect(built.issues, isEmpty);
      final config = await File(
        '${directory.path}/config.json',
      ).writeAsString(built.json!);
      final process = await Process.start(binary!, [
        'run',
        '-c',
        config.path,
        '--stdio-control',
      ]);
      final ready = Completer<void>();
      final pending = <int, Completer<CoreTelemetrySnapshot>>{};
      final errors = <String>[];
      final output = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            final event = jsonDecode(line) as Map<String, dynamic>;
            expect(event['pid'], process.pid);
            if (event['event'] == 'ready' && !ready.isCompleted) {
              ready.complete();
            }
            if (event['event'] == 'telemetry') {
              final waiting = pending.remove(event['request_id']);
              if (event['error'] != null) {
                waiting?.completeError(StateError('Native telemetry failed'));
              } else {
                waiting?.complete(
                  CoreTelemetrySnapshot.fromJson(
                    event['data'] as Map<String, dynamic>,
                  ),
                );
              }
            }
          });
      final stderr = process.stderr.transform(utf8.decoder).listen(errors.add);
      var exited = false;
      final exit = process.exitCode.then((value) {
        exited = true;
        return value;
      });
      addTearDown(() async {
        try {
          if (!exited) {
            process.stdin.writeln('stop');
            await process.stdin.flush();
          }
          await exit.timeout(const Duration(seconds: 5));
        } on TimeoutException {
          process.kill(ProcessSignal.sigkill);
          await exit;
        } finally {
          await output.cancel();
          await stderr.cancel();
        }
      });
      await ready.future.timeout(const Duration(seconds: 10));
      CoreTelemetrySnapshot? latest;
      var id = 0;
      final probe = SingBoxHttpProbe(
        transport: _Mixed(mixed),
        observe: () async {
          final requestId = ++id;
          final reply = Completer<CoreTelemetrySnapshot>();
          pending[requestId] = reply;
          process.stdin.writeln(
            jsonEncode({'method': 'telemetry', 'id': requestId}),
          );
          await process.stdin.flush();
          latest = await reply.future.timeout(const Duration(seconds: 3));
          return latest!;
        },
      );
      for (var index = 0; index < 3; index++) {
        final result = await probe.probe(
          ProbeParams(
            url: 'http://127.0.0.1:${origin.port}/probe-$index',
            timeout: 5000,
            maxBody: 128,
          ),
        );
        expect(result.error, isNull, reason: errors.join());
        expect(result.statusCode, 200);
        expect(result.body, 'independent-probe-receipt');
        expect(result.chains, contains('B'));
        expect(result.chains, isNot(contains('A')));
        expect(result.rule, isNotEmpty);
      }
      expect(origins, 3);
      expect(a.receipts, isEmpty);
      expect(b.receipts, hasLength(3));
      final processes = latest!.processes!;
      final total =
          processes.entries.fold<int>(
            0,
            (sum, entry) => sum + entry.upload + entry.download,
          ) +
          processes.unattributedUpload +
          processes.unattributedDownload;
      expect(total, greaterThan(0));
      if (Platform.isWindows) {
        expect(processes.entries.any((entry) => entry.pid == pid), isTrue);
        expect(
          processes.entries
              .where((entry) => entry.pid == pid)
              .fold<int>(
                0,
                (sum, entry) => sum + entry.upload + entry.download,
              ),
          greaterThan(0),
        );
      }
    },
    skip: enabled
        ? false
        : 'Requires the pinned observation host; no OS proxy or TUN',
  );
}
