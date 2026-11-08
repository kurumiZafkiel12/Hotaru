import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/sing_box/telegram_probe.dart';
import 'package:hotaru/core/adapter.dart';
import 'package:hotaru/core/config/profile.dart';
import 'package:hotaru/core/config/probe_listener.dart';
import 'package:hotaru/core/desktop/lifecycle.dart';
import 'package:hotaru/core/desktop/model.dart';
import 'package:hotaru/core/sing_box/config_preparation.dart';
import 'package:hotaru/core/sing_box/desktop_core.dart';
import 'package:hotaru/core/routed_http.dart';
import 'package:hotaru/core/telemetry.dart';
import 'package:hotaru/models/core.dart';
import 'package:mocktail/mocktail.dart';
import 'support/telemetry_fixture.dart';

class _Lifecycle extends Mock implements DesktopCoreLifecycleController {}

class _Adapter extends Mock implements CoreAdapter {}

class _Binding implements SingBoxConfigurationBinding {
  @override
  final AcceptedSingBoxConfig current;
  _Binding(this.current);
  @override
  CoreAdapter createAdapter() => _Adapter();
  @override
  Future<CoreLifecycleResult> apply(AcceptedSingBoxConfig configuration) =>
      throw UnimplementedError();
}

class _Transport implements CoreRoutedHttp {
  String? selected;
  @override
  Future<T> withRoutedClient<T>(
    Future<T> Function(HttpClient) action, {
    String? outbound,
    Duration timeout = const Duration(minutes: 2),
  }) async {
    selected = outbound;
    final client = HttpClient();
    try {
      return await action(client).timeout(timeout);
    } finally {
      client.close(force: true);
    }
  }
}

void main() {
  test(
    'production TCP probe authenticates the selected node and closes a cancelled handshake',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <Socket>[];
      var held = false;
      final headers = <String>[];
      final entered = StreamController<void>.broadcast();
      server.listen((peer) async {
        sockets.add(peer);
        final stream = StreamIterator(peer);
        final buffer = <int>[];
        Future<Uint8List> read(int n) async {
          while (buffer.length < n) {
            if (!await stream.moveNext()) throw const FormatException('Closed');
            buffer.addAll(stream.current);
          }
          final result = Uint8List.fromList(buffer.sublist(0, n));
          buffer.removeRange(0, n);
          return result;
        }

        try {
          final header = <int>[];
          while (!ascii.decode(header).endsWith('\r\n\r\n')) {
            header.add((await read(1)).single);
          }
          headers.add(ascii.decode(header));
          entered.add(null);
          if (held) {
            await peer.done;
            return;
          }
          peer.add(ascii.encode('HTTP/1.1 200 Connection Established\r\n\r\n'));
          final request = await read(42);
          final response = Uint8List(56);
          final bytes = ByteData.sublistView(response);
          bytes.setUint32(16, 36, Endian.little);
          bytes.setUint32(20, 0x05162463, Endian.little);
          response.setRange(24, 40, request.sublist(26, 42));
          peer.add([14, ...response]);
        } on FormatException {
          peer.destroy();
        } finally {
          await stream.cancel();
        }
      });
      addTearDown(() async {
        for (final socket in sockets) {
          socket.destroy();
        }
        await entered.close();
        await server.close();
      });
      final preparer = SingBoxConfigPreparer();
      final prepared = await preparer.prepare(
        import: () async => CoreConfigImportResult(
          profile: CoreProfileSpec(
            nodes: const [
              CoreNodeSpec(tag: 'B', protocol: CoreNodeProtocol.direct),
            ],
            selectors: [],
            finalOutbound: 'B',
          ),
          issues: [],
        ),
        listeners: CoreListenerSpec(
          mixedPort: 17890,
          controllerPort: 19090,
          secret: 'fixture',
          probe: CoreProbeListenerSpec(
            port: server.port,
            secret: '0123456789abcdef0123456789abcdef',
          ),
        ),
      );
      expect(prepared.status, SingBoxPreparationStatus.ready);
      final accepted = preparer.approve(prepared.candidate!);
      final lifecycle = _Lifecycle();
      when(() => lifecycle.states).thenAnswer((_) => const Stream.empty());
      final core = SingBoxDesktopCore.withConfiguration(
        lifecycle: lifecycle,
        configuration: _Binding(accepted),
      );
      addTearDown(core.adapter.close);
      final transport = _Transport();
      final ordinary = SingBoxTelegramProbe(
        core: core,
        transport: transport,
        observe: () async => CoreTelemetrySnapshot.fromJson(telemetryFixture()),
      );
      final result = await ordinary.probe(
        const ProbeParams(
          url: 'mtproto://149.154.175.50:443/DC1',
          proxyName: 'B',
          timeout: 1000,
        ),
        Completer<void>().future,
      );
      expect(result.error, isNull);
      expect(result.statusCode, 200);
      expect(result.chains, isEmpty);
      expect(headers.single, startsWith('CONNECT 149.154.175.50:443 HTTP/1.1'));
      expect(
        headers.single,
        contains(
          'Proxy-Authorization: Basic ${base64.encode(utf8.encode('${CoreProbeListenerSpec.username('B')}:0123456789abcdef0123456789abcdef'))}',
        ),
      );
      expect(transport.selected, 'B');
      held = true;
      final cancelled = Completer<void>();
      final reached = entered.stream.first;
      final pending = ordinary.probe(
        const ProbeParams(
          url: 'mtproto://149.154.175.50:443/DC1',
          proxyName: 'B',
          timeout: 1000,
        ),
        cancelled.future,
      );
      await reached.timeout(const Duration(seconds: 2));
      cancelled.complete();
      expect((await pending).error, 'cancelled');
    },
  );

  for (final variant in [
    'valid',
    'extended',
    'wrong-nonce',
    'wrong-constructor',
    'oversized',
  ]) {
    test('MTProto TCP exchange validates $variant reply', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = server.first;
      final client = await Socket.connect(
        InternetAddress.loopbackIPv4,
        server.port,
      );
      final peer = await accepted;
      addTearDown(() async {
        client.destroy();
        peer.destroy();
        await server.close();
      });
      final request = <int>[];
      peer.listen((chunk) {
        request.addAll(chunk);
        if (request.length < 42) return;
        expect(request.take(2), [0xef, 10]);
        expect(
          ByteData.sublistView(
            Uint8List.fromList(request),
          ).getUint32(22, Endian.little),
          0xbe7e8ef1,
        );
        if (variant == 'oversized') {
          peer.add([0x7f, 1, 4, 0]);
          return;
        }
        final reply = Uint8List(56);
        final data = ByteData.sublistView(reply);
        data.setUint32(16, 36, Endian.little);
        data.setUint32(
          20,
          variant == 'wrong-constructor' ? 0 : 0x05162463,
          Endian.little,
        );
        reply.setRange(24, 40, request.sublist(26, 42));
        if (variant == 'wrong-nonce') reply[24] ^= 1;
        peer.add(variant == 'extended' ? [0x7f, 14, 0, 0] : [14]);
        peer.add(reply.sublist(0, 21));
        peer.add(reply.sublist(21));
      });
      final stream = StreamIterator(client);
      final buffered = <int>[];
      Future<Uint8List> read(int count) async {
        while (buffered.length < count) {
          if (!await stream.moveNext()) {
            throw const FormatException('Truncated');
          }
          buffered.addAll(stream.current);
        }
        final result = Uint8List.fromList(buffered.sublist(0, count));
        buffered.removeRange(0, count);
        return result;
      }

      final result = telegramHandshake(
        client,
        read,
      ).timeout(const Duration(seconds: 3));
      if (variant == 'valid' || variant == 'extended') {
        await result;
      } else {
        await expectLater(result, throwsFormatException);
      }
      await stream.cancel();
    });
  }
}
