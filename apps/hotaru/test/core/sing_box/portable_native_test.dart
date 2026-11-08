import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/bootstrap_windows.dart';
import 'package:hotaru/core/desktop/model.dart';
import 'package:hotaru/models/models.dart' show SetupParams;

import 'support/windows_process_witness.dart';

void main() {
  final bundle = Platform.environment['HOTARU_NATIVE_PORTABLE_BUNDLE'];
  test(
    'portable application without a Helper forwards and exits through the verified owned pipe host',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'hotaru-portable-',
      );
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final receipts = <String>[];
      origin.listen((request) async {
        receipts.add(request.uri.path);
        request.response.write('portable-independent-receipt');
        await request.response.close();
      });
      final mixed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final mixedPort = mixed.port;
      await mixed.close();
      final config = File('${directory.path}/config.yaml');
      final application = await WindowsCoreApplication.create(
        homeDirectory: directory.path,
        configPath: config.path,
        mixedPort: mixedPort,
        providerFiles: () async => {},
        resolveGeo: (_) async => {},
        review: (_) async => true,
        persistTraffic: (_) async {},
        onError: (error, _) => fail('$error'),
        onEvent: (_) {},
        bundleDirectory: bundle,
      );
      final witnesses = <WindowsProcessWitness>[];
      void witness() {
        final state = application.core.lifecycle.state as DesktopCoreRunning;
        expect(state.session.lease.owner, CoreProcessOwner.direct);
        witnesses.add(WindowsProcessWitness.open(state.session.pid));
      }

      try {
        await application.controller.start();
        witness();
        await config.writeAsString(
          jsonEncode({
            'mixed-port': mixedPort,
            'ipv6': true,
            'proxies': [
              {'name': 'direct', 'type': 'direct'},
            ],
            'rules': ['MATCH,direct'],
          }),
        );
        expect(
          await application.controller.setupConfig(
            params: const SetupParams(
              selectedMap: {},
              testUrl: 'http://fixture.invalid',
            ),
            profileId: 12,
          ),
          '',
        );
        expect(witnesses.last.hasExited, isTrue);
        witness();
        expect(await application.controller.startListener(), isTrue);
        expect(witnesses.last.hasExited, isTrue);
        witness();
        final body = await application.controller.withRoutedClient((
          client,
        ) async {
          final request = await client.getUrl(
            Uri.parse('http://127.0.0.1:${origin.port}/portable'),
          );
          final response = await request.close();
          expect(response.statusCode, 200);
          return utf8.decoder.bind(response).join();
        });
        expect(body, 'portable-independent-receipt');
        expect(receipts, ['/portable']);
      } finally {
        await application.controller.close();
        try {
          expect(witnesses, isNotEmpty);
          expect(witnesses.every((process) => process.hasExited), isTrue);
        } finally {
          for (final process in witnesses) {
            process.close();
          }
          await origin.close(force: true);
          await directory.delete(recursive: true);
        }
      }
    },
    skip: Platform.isWindows && bundle != null
        ? false
        : 'Opt-in disposable Windows portable integration only',
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
