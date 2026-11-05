import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/config/profile.dart';
import 'package:hotaru/core/desktop/model.dart';
import 'package:hotaru/core/desktop/process_probe.dart';
import 'package:hotaru/core/sing_box/helper_desktop_core.dart';

import '../../plugins/code_forge/support.dart' show initEditorNative;

final _environment = Platform.environment;
final _enabled =
    Platform.isWindows &&
    _environment['CI'] == 'true' &&
    _environment['HOTARU_NATIVE_HELPER_BUNDLE'] != null;

Future<void> _expectSystem(int processId) async {
  final command =
      "\$ErrorActionPreference='Stop'; "
      "\$owner=Get-CimInstance Win32_Process -Filter 'ProcessId=$processId' | Invoke-CimMethod -MethodName GetOwnerSid; "
      "if (\$owner.ReturnValue -ne 0) { throw 'Cannot query process owner' }; \$owner.Sid";
  final process = await Process.start('powershell.exe', [
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    command,
  ]);
  final output = utf8.decoder.bind(process.stdout).join();
  final errors = utf8.decoder.bind(process.stderr).join();
  var exited = false;
  try {
    final status = await process.exitCode.timeout(const Duration(seconds: 10));
    exited = true;
    expect(status, 0);
    expect((await output).trim(), 'S-1-5-18');
    expect((await errors).trim(), isEmpty);
  } finally {
    if (!exited) {
      process.kill();
      await process.exitCode.timeout(const Duration(seconds: 2));
    }
  }
}

void main() {
  test(
    'real Flutter Rust IPC owns a SYSTEM Helper TUN session through restart and close',
    () async {
      await initEditorNative();
      final service = await createSingBoxHelperCore(
        bundleDirectory: _environment['HOTARU_NATIVE_HELPER_BUNDLE']!,
        profile: CoreProfileSpec(
          nodes: [
            CoreNodeSpec(
              tag: 'proof',
              protocol: CoreNodeProtocol.http,
              server: '127.0.0.1',
              port: int.parse(_environment['HOTARU_NATIVE_PROXY_PORT']!),
            ),
            const CoreNodeSpec(
              tag: 'direct',
              protocol: CoreNodeProtocol.direct,
            ),
          ],
          selectors: [
            CoreSelectorSpec(tag: 'selected', members: ['proof', 'direct']),
          ],
          finalOutbound: 'selected',
        ),
        listeners: CoreListenerSpec(
          mixedPort: int.parse(_environment['HOTARU_NATIVE_MIXED_PORT']!),
          controllerPort: int.parse(_environment['HOTARU_NATIVE_API_PORT']!),
          secret: 'native-fixture-secret',
          tun: CoreTunSpec(
            interfaceName: _environment['HOTARU_NATIVE_TUN_NAME']!,
            addresses: ['198.18.8.1/30'],
            autoRoute: false,
          ),
        ),
      );
      final pids = <int>[];
      final client = HttpClient()..findProxy = (_) => 'DIRECT';
      client.connectionTimeout = const Duration(seconds: 10);
      try {
        final starts = await Future.wait([service.start(), service.start()]);
        expect(starts.length, 2);
        expect(starts.map((result) => result.session!.pid).toSet().length, 1);
        final first = service.lifecycle.state as DesktopCoreRunning;
        expect(first.session.owner, CoreProcessOwner.helper);
        pids.add(first.session.pid);
        await _expectSystem(first.session.pid);
        await service.adapter.selectOutbound('selected', 'direct');
        expect(
          (await service.adapter.outbounds())
              .singleWhere((node) => node.name == 'selected')
              .selected,
          'direct',
        );
        await service.adapter.selectOutbound('selected', 'proof');
        final request = await client.getUrl(Uri.parse('http://198.18.8.2/'));
        final response = await request.close().timeout(
          const Duration(seconds: 10),
        );
        expect(response.statusCode, 200);
        expect(
          await utf8.decoder
              .bind(response)
              .join()
              .timeout(const Duration(seconds: 10)),
          'helper-tun-proof',
        );

        await service.restart();
        final second = service.lifecycle.state as DesktopCoreRunning;
        pids.add(second.session.pid);
        expect(second.session.sessionId, isNot(first.session.sessionId));
        expect(second.session.pid, isNot(first.session.pid));
        expect(await isProcessAlive(first.session.pid), isFalse);
        expect(
          (await service.adapter.outbounds()).any(
            (node) => node.name == 'proof',
          ),
          isTrue,
        );

        await service.stop();
        expect(service.lifecycle.state, isA<DesktopCoreIdle>());
        expect(await isProcessAlive(second.session.pid), isFalse);
        await service.start();
        final third = service.lifecycle.state as DesktopCoreRunning;
        pids.add(third.session.pid);
        await service.close();
        await service.close();
        expect(service.lifecycle.state, isA<DesktopCoreClosed>());
        expect(await isProcessAlive(third.session.pid), isFalse);
        final badBundle = await Directory.systemTemp.createTemp(
          'hotaru_bad_digest_',
        );
        try {
          final manifest =
              jsonDecode(
                    await File(
                      '${_environment['HOTARU_NATIVE_HELPER_BUNDLE']!}/manifest.json',
                    ).readAsString(),
                  )
                  as Map<String, dynamic>;
          manifest['coreSha256'] = '0' * 64;
          await File(
            '${badBundle.path}/manifest.json',
          ).writeAsString(jsonEncode(manifest));
          final denied = await createSingBoxHelperCore(
            bundleDirectory: badBundle.path,
            profile: CoreProfileSpec(
              nodes: const [
                CoreNodeSpec(tag: 'direct', protocol: CoreNodeProtocol.direct),
              ],
              selectors: [],
              finalOutbound: 'direct',
            ),
            listeners: CoreListenerSpec(
              mixedPort: int.parse(_environment['HOTARU_NATIVE_MIXED_PORT']!),
              controllerPort: int.parse(
                _environment['HOTARU_NATIVE_API_PORT']!,
              ),
              secret: 'denied-fixture-secret',
            ),
          );
          try {
            await expectLater(
              denied.start(),
              throwsA(isA<DesktopCoreFailure>()),
            );
            expect(
              (denied.lifecycle.state as DesktopCoreFailed).failure.pid,
              isNull,
            );
          } finally {
            await denied.close();
          }
        } finally {
          await badBundle.delete(recursive: true);
        }
        await File(_environment['HOTARU_NATIVE_HELPER_RESULT']!).writeAsString(
          jsonEncode({
            'native_ipc': true,
            'helper_system': true,
            'tun_payload': true,
            'restart': true,
            'terminal_close': true,
            'digest_mismatch_refused': true,
            'pids': pids,
          }),
        );
      } finally {
        client.close(force: true);
        await service.close();
      }
    },
    skip: _enabled ? false : 'Opt-in disposable Windows SCM integration only',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
