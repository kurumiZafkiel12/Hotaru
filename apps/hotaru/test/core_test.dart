import 'package:flutter_test/flutter_test.dart';

import 'dart:io';

import 'package:hotaru/core/mihomo_controller.dart';

void main() {
  test('missing executable fails cleanly and permits retry', () async {
    final directory = await Directory.systemTemp.createTemp('hotaru-test-');
    final core = MihomoController();
    try {
      for (var attempt = 0; attempt < 2; attempt++) {
        await expectLater(
          core.startDiagnostic(
            '${directory.path}/missing.exe',
            directory,
            19090,
          ),
          throwsArgumentError,
        );
        expect(core.status, CoreStatus.failed);
      }
      await core.stop();
      expect(core.status, CoreStatus.stopped);
      expect(await File('${directory.path}/diagnostic.json').exists(), false);
    } finally {
      await core.dispose();
      await directory.delete(recursive: true);
    }
  });
  test('diagnostic config never enables network interception', () {
    final config = MihomoController.diagnosticConfig(
      19090,
      MihomoController.newSecret(),
    );
    expect(config['mixed-port'], 0);
    expect(config['allow-lan'], false);
    expect(config['external-controller'], '127.0.0.1:19090');
    expect((config['tun'] as Map)['enable'], false);
  });
  test('controller rejects invalid ports and short secrets', () {
    expect(
      () => MihomoController.diagnosticConfig(80, 'a'),
      throwsArgumentError,
    );
    expect(
      () => MihomoController.diagnosticConfig(70000, 'a' * 40),
      throwsArgumentError,
    );
  });
  test('findFreePort returns a bindable loopback port', () async {
    final port = await MihomoController.findFreePort();
    expect(port, inInclusiveRange(1024, 65535));
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    await probe.close();
  });
  test('dispose is idempotent, never throws, and blocks reuse', () async {
    final core = MihomoController();
    await core.dispose();
    await core.dispose();
    expect(core.status, CoreStatus.stopped);
    final directory = await Directory.systemTemp.createTemp('hotaru-test-');
    try {
      await expectLater(
        core.startDiagnostic('${directory.path}/missing.exe', directory, 19090),
        throwsStateError,
      );
    } finally {
      await directory.delete(recursive: true);
    }
  });
  test('each launch gets a different strong secret', () {
    final a = MihomoController.newSecret();
    expect(a.length, greaterThanOrEqualTo(43));
    expect(MihomoController.newSecret(), isNot(a));
  });
}
