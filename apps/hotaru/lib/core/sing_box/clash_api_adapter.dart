import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import '../adapter.dart';
import '../config/probe_listener.dart';
import '../outbound_http.dart';
import '../telemetry.dart';
import '../routing_mode.dart';
import 'outbound_http.dart';

final class SingBoxClashApiAdapter
    implements CoreAdapter, CoreOutboundHttp, CoreTelemetry, CoreRoutingModes {
  final Uri endpoint;
  final String _secret;
  final HttpClient _client;
  final SingBoxOutboundHttp _outboundHttp;
  final Future<CoreTelemetrySnapshot> Function()? _telemetry;
  bool _closed = false;

  SingBoxClashApiAdapter({
    required this.endpoint,
    required String secret,
    CoreProbeListenerSpec? probe,
    Iterable<String> probeOutbounds = const [],
    Future<CoreTelemetrySnapshot> Function()? telemetry,
  }) : _secret = secret,
       _telemetry = telemetry,
       _outboundHttp = SingBoxOutboundHttp(
         listener: probe,
         outbounds: probeOutbounds,
       ),
       _client = HttpClient() {
    if (endpoint.scheme != 'http' ||
        !const ['127.0.0.1', '::1'].contains(endpoint.host) ||
        !endpoint.hasPort ||
        endpoint.port == 0 ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.hasQuery ||
        endpoint.hasFragment ||
        !const ['', '/'].contains(endpoint.path) ||
        secret.isEmpty ||
        secret.contains(RegExp(r'[\r\n]'))) {
      _client.close(force: true);
      throw ArgumentError(
        'A loopback controller and nonempty secret are required',
      );
    }
    _client.findProxy = (_) => 'DIRECT';
  }

  Future<Object?> _request(
    String method,
    List<String> path, {
    Map<String, String>? query,
    Object? body,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (_closed) throw const CoreAdapterException('closed');
    HttpClientRequest? pending;
    var expired = false;
    Future<Object?> send() async {
      try {
        final request = await _client.openUrl(
          method,
          endpoint.replace(pathSegments: path, queryParameters: query),
        );
        pending = request;
        if (expired || _closed) {
          request.abort();
          throw CoreAdapterException(expired ? 'timeout' : 'closed');
        }
        request.followRedirects = false;
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_secret');
        if (body != null) {
          request.headers.contentType = ContentType.json;
          request.write(jsonEncode(body));
        }
        final response = await request.close();
        if (response.statusCode < 200 || response.statusCode >= 300) {
          request.abort();
          throw CoreAdapterException('http', status: response.statusCode);
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > 16 * 1024 * 1024) {
            request.abort();
            throw const CoreAdapterException('response_too_large');
          }
          bytes.addAll(chunk);
        }
        if (bytes.isEmpty) return null;
        return await _decode(bytes);
      } on SocketException {
        throw const CoreAdapterException('transport');
      } on HttpException {
        throw const CoreAdapterException('transport');
      } on FormatException {
        throw const CoreAdapterException('invalid_response');
      }
    }

    return send().timeout(
      timeout,
      onTimeout: () {
        expired = true;
        pending?.abort();
        throw const CoreAdapterException('timeout');
      },
    );
  }

  static Future<Object?> _decode(List<int> bytes) {
    return Isolate.run(() => jsonDecode(utf8.decode(bytes)));
  }

  Future<String> version({
    Duration timeout = const Duration(seconds: 1),
  }) async {
    final result = _object(
      await _request('GET', ['version'], timeout: timeout),
    );
    return _string(result['version']);
  }

  @override
  Future<CoreRoutingMode> routingMode() async {
    final result = _object(await _request('GET', ['configs']));
    final name = _string(result['mode']);
    for (final mode in CoreRoutingMode.values) {
      if (mode.name == name) return mode;
    }
    throw const CoreAdapterException('unsupported_routing_mode');
  }

  @override
  Future<void> setRoutingMode(CoreRoutingMode mode) async {
    await _request('PATCH', ['configs'], body: {'mode': mode.name});
    if (await routingMode() != mode) {
      throw const CoreAdapterException('route_changed');
    }
  }

  @override
  Future<List<CoreOutbound>> outbounds() async {
    final result = _object(await _request('GET', ['proxies']));
    return Isolate.run(() => _outbounds(result));
  }

  static List<CoreOutbound> _outbounds(Map<String, dynamic> result) {
    final proxies = _object(result['proxies']);
    return List.unmodifiable(
      proxies.entries.map((entry) {
        final proxy = _object(entry.value);
        return CoreOutbound(
          name: entry.key,
          type: _string(proxy['type']),
          members: proxy['all'] == null ? const [] : _strings(proxy['all']),
          selected: proxy['now'] == null ? null : _string(proxy['now']),
        );
      }),
    );
  }

  @override
  Future<void> selectOutbound(String group, String outbound) async {
    await _request('PUT', ['proxies', group], body: {'name': outbound});
  }

  @override
  Future<Duration> delay(String outbound, Uri target, Duration timeout) async {
    if (target.scheme != 'https' ||
        target.host.isEmpty ||
        target.userInfo.isNotEmpty ||
        target.hasFragment ||
        timeout.inMilliseconds < 1 ||
        timeout.inMilliseconds > 32767) {
      throw ArgumentError('Delay requires HTTPS and a timeout of 1–32767ms');
    }
    final response = _object(
      await _request(
        'GET',
        ['proxies', outbound, 'delay'],
        query: {
          'url': target.toString(),
          'timeout': '${timeout.inMilliseconds}',
        },
        timeout: timeout + const Duration(seconds: 2),
      ),
    );
    final milliseconds = _counter(response['delay']);
    if (milliseconds == 0) {
      throw const CoreAdapterException('invalid_response');
    }
    return Duration(milliseconds: milliseconds);
  }

  @override
  Future<CoreConnections> connections() async {
    final result = _object(await _request('GET', ['connections']));
    return Isolate.run(() => _connections(result));
  }

  static CoreConnections _connections(Map<String, dynamic> result) {
    final raw = result['connections'];
    if (raw is! List) throw const CoreAdapterException('invalid_response');
    return CoreConnections(
      uploadTotal: _counter(result['uploadTotal']),
      downloadTotal: _counter(result['downloadTotal']),
      entries: List.unmodifiable(
        raw.map((value) {
          final entry = _object(value);
          final metadata = _object(entry['metadata']);
          final processPath = metadata['processPath'];
          return CoreConnection(
            id: _string(entry['id']),
            inbound: _string(metadata['type']),
            network: _string(metadata['network']),
            host: _string(metadata['host']),
            destinationIp: _string(metadata['destinationIP']),
            destinationPort: _string(metadata['destinationPort']),
            processPath: processPath == null || processPath == ''
                ? null
                : _string(processPath),
            chain: _strings(entry['chains']),
            rule: _string(entry['rule']),
            upload: _counter(entry['upload']),
            download: _counter(entry['download']),
          );
        }),
      ),
    );
  }

  @override
  Future<void> closeConnection(String id) async {
    await _request('DELETE', ['connections', id]);
  }

  @override
  Future<CoreTelemetrySnapshot> telemetry() async {
    if (_closed) throw const CoreAdapterException('closed');
    final read = _telemetry;
    if (read == null) throw const CoreAdapterException('telemetry_unavailable');
    final result = await read();
    if (_closed) throw const CoreAdapterException('closed');
    return result;
  }

  @override
  Future<T> withOutboundClient<T>(
    String outbound,
    Future<T> Function(HttpClient client) action, {
    Duration timeout = const Duration(minutes: 2),
  }) => _outboundHttp.withOutboundClient(outbound, action, timeout: timeout);

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _outboundHttp.close();
    _client.close(force: true);
  }

  static Map<String, dynamic> _object(Object? value) {
    if (value is Map<String, dynamic>) return value;
    throw const CoreAdapterException('invalid_response');
  }

  static String _string(Object? value) {
    if (value is String) return value;
    throw const CoreAdapterException('invalid_response');
  }

  static int _counter(Object? value) {
    if (value is int && value >= 0) return value;
    throw const CoreAdapterException('invalid_response');
  }

  static List<String> _strings(Object? value) {
    if (value is List && value.every((entry) => entry is String)) {
      return List.unmodifiable(value.cast<String>());
    }
    throw const CoreAdapterException('invalid_response');
  }
}
