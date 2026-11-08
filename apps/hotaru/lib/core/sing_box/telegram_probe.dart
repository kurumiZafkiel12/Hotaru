import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import '../../models/core.dart';
import '../adapter.dart';
import '../config/probe_listener.dart';
import '../routed_http.dart';
import '../telemetry.dart';
import 'desktop_core.dart';

const telegramDataCenters = [
  '149.154.175.50',
  '149.154.167.51',
  '149.154.175.100',
  '149.154.167.91',
  '91.108.56.130',
];

final class SingBoxTelegramProbe {
  final SingBoxDesktopCore core;
  final CoreRoutedHttp transport;
  final Future<CoreTelemetrySnapshot> Function() observe;

  SingBoxTelegramProbe({
    required this.core,
    required this.transport,
    required this.observe,
  });

  Future<ProbeResult> probe(ProbeParams params, Future<void> cancelled) async {
    Socket? socket;
    ConnectionTask<Socket>? connecting;
    _ExactBytes? reader;
    var active = true;
    final watch = Stopwatch()..start();
    final cancellation = cancelled.then<ProbeResult>(
      (_) => throw const CoreAdapterException('cancelled'),
    );
    cancellation.ignore();
    try {
      final target = Uri.parse(params.url);
      if (target.scheme != 'mtproto' ||
          target.port != 443 ||
          !telegramDataCenters.contains(target.host)) {
        throw const CoreAdapterException('invalid_probe_target');
      }
      final configuration = core.configuration;
      if (configuration == null || !configuration.listeners.inboundsEnabled) {
        throw const CoreAdapterException('applied_profile_unavailable');
      }
      final listeners = configuration.listeners;
      final probe = listeners.activeProbe;
      final named = params.proxyName.isNotEmpty;
      if (named && probe == null) {
        throw const CoreAdapterException('outbound_http_unavailable');
      }
      final listen = listeners.inbound?.listen ?? '127.0.0.1';
      final host = named
          ? '127.0.0.1'
          : switch (listen) {
              '0.0.0.0' => '127.0.0.1',
              '::' => '::1',
              _ => listen,
            };
      final user = listeners.inbound?.users.firstOrNull;
      final auth = named
          ? (
              CoreProbeListenerSpec.username(
                params.proxyName == 'DIRECT'
                    ? configuration.directOutbound
                    : params.proxyName,
              ),
              probe!.secret,
            )
          : user == null
          ? null
          : (user.username, user.password);
      return await transport.withRoutedClient(
        (_) async {
          Future<ProbeResult> execute() async {
            final started = DateTime.now().toUtc();
            final task = await Socket.startConnect(
              host,
              named ? probe!.port : listeners.mixedPort,
            );
            connecting = task;
            try {
              socket = await task.socket.then((value) {
                if (!active) {
                  value.destroy();
                  throw const CoreAdapterException('cancelled');
                }
                return value;
              });
            } finally {
              task.cancel();
            }
            final connected = socket!;
            reader = _ExactBytes(connected);
            connected.add(
              ascii.encode(
                'CONNECT ${target.host}:443 HTTP/1.1\r\n'
                'Host: ${target.host}:443\r\n'
                '${auth == null ? '' : 'Proxy-Authorization: Basic ${base64.encode(utf8.encode('${auth.$1}:${auth.$2}'))}\r\n'}\r\n',
              ),
            );
            final header = await reader!.header();
            if (!RegExp(r'^HTTP/1\.[01] 200(?: |\r)').hasMatch(header)) {
              throw const CoreAdapterException('proxy_connect_failed');
            }
            await telegramHandshake(connected, reader!.read);
            final received = DateTime.now().toUtc();
            final sample = await observe();
            final sourcePort = connected.port;
            final sourceIp = connected.address.address;
            final destination = target.host;
            final observed = await _matchTelegramObservation(
              sample,
              sourcePort,
              sourceIp,
              destination,
              started,
              received,
            );
            return ProbeResult(
              url: params.url,
              statusCode: 200,
              delay: watch.elapsedMilliseconds,
              chains: observed?.chain ?? const [],
              rule: observed?.rule ?? '',
            );
          }

          return Future.any([execute(), cancellation]);
        },
        outbound: named ? params.proxyName : null,
        timeout: Duration(
          milliseconds: params.timeout <= 0 ? 10000 : params.timeout,
        ),
      );
    } catch (error) {
      return ProbeResult(
        url: params.url,
        delay: watch.elapsedMilliseconds,
        error: error is CoreAdapterException
            ? error.code
            : error is TimeoutException
            ? 'timeout'
            : 'mtproto_handshake_failed',
      );
    } finally {
      active = false;
      connecting?.cancel();
      socket?.destroy();
      await reader?.close();
    }
  }
}

Future<void> telegramHandshake(
  Socket socket,
  Future<Uint8List> Function(int) read,
) async {
  final random = Random.secure();
  final nonce = List<int>.generate(16, (_) => random.nextInt(256));
  final request = Uint8List(42)
    ..[0] = 0xef
    ..[1] = 10;
  final data = ByteData.sublistView(request);
  data.setUint64(
    10,
    (DateTime.now().millisecondsSinceEpoch ~/ 1000) << 32,
    Endian.little,
  );
  data.setUint32(18, 20, Endian.little);
  data.setUint32(22, 0xbe7e8ef1, Endian.little);
  request.setRange(26, 42, nonce);
  socket.add(request);
  var words = (await read(1)).single;
  if (words == 0x7f) {
    final extended = await read(3);
    words = extended[0] | extended[1] << 8 | extended[2] << 16;
  }
  if (words < 14 || words > 1024) {
    throw const FormatException('Invalid MTProto frame');
  }
  final response = await read(words * 4);
  final body = ByteData.sublistView(response);
  if (body.getUint64(0, Endian.little) != 0 ||
      body.getUint32(16, Endian.little) != response.length - 20 ||
      body.getUint32(20, Endian.little) != 0x05162463 ||
      List.generate(
        16,
        (index) => response[index + 24] == nonce[index],
      ).contains(false)) {
    throw const FormatException('MTProto nonce or constructor mismatch');
  }
}

final class _ExactBytes {
  final StreamIterator<Uint8List> _stream;
  Uint8List _chunk = Uint8List(0);
  int _offset = 0;
  _ExactBytes(Socket socket) : _stream = StreamIterator(socket);
  Future<Uint8List> read(int count) async {
    final result = Uint8List(count);
    var written = 0;
    while (written < count) {
      if (_offset == _chunk.length) {
        if (!await _stream.moveNext()) {
          throw const FormatException('Truncated TCP response');
        }
        _chunk = _stream.current;
        _offset = 0;
      }
      final take = min(count - written, _chunk.length - _offset);
      result.setRange(written, written + take, _chunk, _offset);
      written += take;
      _offset += take;
    }
    return result;
  }

  Future<String> header() async {
    final bytes = <int>[];
    while (bytes.length < 8192) {
      bytes.add((await read(1)).single);
      if (bytes.length >= 4 &&
          bytes[bytes.length - 4] == 13 &&
          bytes[bytes.length - 3] == 10 &&
          bytes[bytes.length - 2] == 13 &&
          bytes.last == 10) {
        return ascii.decode(bytes);
      }
    }
    throw const FormatException('Oversized proxy response');
  }

  Future<void> close() => _stream.cancel();
}

Future<CoreObservedConnection?> _matchTelegramObservation(
  CoreTelemetrySnapshot sample,
  int sourcePort,
  String sourceIp,
  String destination,
  DateTime started,
  DateTime received,
) => Isolate.run(() {
  final matches = [...sample.active, ...sample.closed]
      .where(
        (entry) =>
            entry.sourcePort == sourcePort &&
            entry.sourceIp == sourceIp &&
            entry.destinationIp == destination &&
            entry.destinationPort == 443 &&
            !entry.createdAt.isBefore(started) &&
            !entry.createdAt.isAfter(received),
      )
      .toList();
  return matches.length == 1 ? matches.single : null;
});
