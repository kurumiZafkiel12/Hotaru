import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/config/profile.dart';
import 'package:hotaru/core/config/clash_subscription.dart';
import 'package:hotaru/core/desktop/model.dart';
import 'package:hotaru/core/desktop/process_probe.dart';
import 'package:hotaru/core/sing_box/helper_desktop_core.dart';

import '../../plugins/code_forge/support.dart' show initEditorNative;
import 'support/dns_fixture.dart';

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
      final dnsServer = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(dnsServer.close);
      var dnsReceipts = 0;
      dnsServer.listen((event) {
        if (event != RawSocketEvent.read) return;
        final packet = dnsServer.receive();
        if (packet == null) return;
        final expectedQuestion = question('helper-dns.invalid');
        expect(
          packet.data.sublist(12, expectedQuestion.length),
          expectedQuestion.sublist(12),
        );
        dnsReceipts++;
        dnsServer.send(answer(packet.data), packet.address, packet.port);
      });
      final providerServer = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => providerServer.close(force: true));
      var providerAvailable = true;
      var providerRequests = 0;
      providerServer.listen((request) async {
        providerRequests++;
        expect(
          request.headers.value('authorization'),
          'provider-fixture-token',
        );
        request.response.statusCode = providerAvailable ? 200 : 503;
        request.response.write(
          jsonEncode({
            'proxies': [
              {
                'name': 'proof',
                'type': 'http',
                'server': '127.0.0.1',
                'port': int.parse(_environment['HOTARU_NATIVE_PROXY_PORT']!),
              },
            ],
          }),
        );
        await request.response.close();
      });
      final providerClient = HttpClient()..findProxy = (_) => 'DIRECT';
      providerClient.connectionTimeout = const Duration(seconds: 10);
      addTearDown(() => providerClient.close(force: true));
      final importer = ClashSubscriptionImporter(
        resolve: (provider) async {
          expect(provider.outbound, 'DIRECT');
          final request = await providerClient.getUrl(provider.url!);
          provider.headers.forEach((name, values) {
            for (final value in values) {
              request.headers.add(name, value);
            }
          });
          final response = await request.close().timeout(
            const Duration(seconds: 10),
          );
          if (response.statusCode != 200) {
            await response.drain<void>();
            throw StateError('Provider fixture is unavailable');
          }
          final bytes = <int>[];
          await for (final chunk in response.timeout(
            const Duration(seconds: 10),
          )) {
            if (bytes.length + chunk.length > provider.maxBytes) {
              throw StateError('Provider byte limit');
            }
            bytes.addAll(chunk);
          }
          return utf8.decode(bytes);
        },
      );
      final source = jsonEncode({
        'dns': {
          'enable': true,
          'nameserver': ['udp://127.0.0.1:${dnsServer.port}'],
          'use-hosts': false,
          'use-system-hosts': false,
        },
        'proxies': [
          {'name': 'direct', 'type': 'direct'},
        ],
        'proxy-providers': {
          'remote': {
            'type': 'http',
            'url': 'http://127.0.0.1:${providerServer.port}/proxies',
            'proxy': 'DIRECT',
            'interval': 1800,
            'header': {
              'Authorization': ['provider-fixture-token'],
            },
          },
        },
        'proxy-groups': [
          {
            'name': 'selected',
            'type': 'select',
            'proxies': ['direct'],
            'use': ['remote'],
          },
        ],
        'rules': ['MATCH,selected'],
      });
      final imported = await importer.import(source);
      expect(imported.issues, isEmpty);
      final service = await createSingBoxHelperCore(
        bundleDirectory: _environment['HOTARU_NATIVE_HELPER_BUNDLE']!,
        profile: imported.profile!,
        listeners: CoreListenerSpec(
          mixedPort: int.parse(_environment['HOTARU_NATIVE_MIXED_PORT']!),
          controllerPort: int.parse(_environment['HOTARU_NATIVE_API_PORT']!),
          secret: 'native-fixture-secret',
          tun: CoreTunSpec(
            interfaceName: _environment['HOTARU_NATIVE_TUN_NAME']!,
            addresses: ['198.18.8.1/30'],
            autoRoute: false,
            hijackDns: true,
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

        final dnsResponse = await udpQuery(
          53,
          question('helper-dns.invalid'),
          address: InternetAddress('198.18.8.2'),
        );
        expect(dnsResponse.sublist(dnsResponse.length - 4), [192, 0, 2, 45]);
        expect(dnsReceipts, 1);

        providerAvailable = false;
        final failedRefresh = await importer.import(source);
        expect(failedRefresh.profile, isNull);
        expect(
          failedRefresh.issues.map((issue) => issue.code),
          contains('provider_resolution_failed'),
        );
        expect(
          (service.lifecycle.state as DesktopCoreRunning).session.pid,
          first.session.pid,
        );
        expect(
          (await service.adapter.outbounds()).any(
            (node) => node.name == 'proof',
          ),
          isTrue,
        );
        expect(providerRequests, 2);

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
            'provider_import': true,
            'failed_provider_keeps_session': true,
            'helper_system': true,
            'tun_payload': true,
            'tun_dns_receipt': true,
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
