import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import '../adapter.dart';
import '../logs.dart';
import 'log_stream.dart';
import '../config/test_target.dart';
import '../config/probe_listener.dart';
import '../outbound_http.dart';
import '../telemetry.dart';
import '../routing_mode.dart';
import '../maintenance.dart';
import 'outbound_http.dart';

final class SingBoxClashApiAdapter
    implements
        CoreAdapter,
        CoreLogSource,
        CoreOutboundHttpClients,
        CoreTelemetry,
        CoreConnectionPathTelemetry,
        CoreRoutingModes,
        CoreRuntimeMaintenance,
        CoreConnectionMaintenance {
  final Uri endpoint;
  final String _secret;
  final HttpClient _client;
  final SingBoxOutboundHttp _outboundHttp;
  final Future<CoreTelemetrySnapshot> Function()? _telemetry;
  final Future<CoreTelemetrySnapshot> Function()? _pathTelemetry;
  final CoreRuntimeMaintenance? _runtime;
  bool _closed = false;
  final Set<SingBoxLogStream> _logs = {};

  SingBoxClashApiAdapter({
    required this.endpoint,
    required String secret,
    CoreProbeListenerSpec? probe,
    Iterable<String> probeOutbounds = const [],
    Future<CoreTelemetrySnapshot> Function()? telemetry,
    Future<CoreTelemetrySnapshot> Function()? pathTelemetry,
    CoreRuntimeMaintenance? runtime,
  }) : _secret = secret,
       _telemetry = telemetry,
       _pathTelemetry = pathTelemetry,
       _runtime = runtime,
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

  @override
  Stream<CoreLogMessage> logs() {
    if (_closed) throw const CoreAdapterException('closed');
    late SingBoxLogStream source;
    source = SingBoxLogStream(
      endpoint: endpoint,
      secret: _secret,
      onClose: () => _logs.remove(source),
    );
    _logs.add(source);
    return source.stream;
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
  Future<void> closeConnections() async {
    await _request('DELETE', ['connections']);
  }

  @override
  Future<void> clearDnsCache() async {
    await _request('POST', ['cache', 'dns', 'flush']);
  }

  CoreRuntimeMaintenance get _maintenance {
    if (_closed) throw const CoreAdapterException('closed');
    final runtime = _runtime;
    if (runtime == null) {
      throw const CoreAdapterException('runtime_maintenance_unavailable');
    }
    return runtime;
  }

  @override
  Future<void> collectMemory() async {
    await _maintenance.collectMemory();
  }

  @override
  Future<void> resetDnsConnections() async {
    await _maintenance.resetDnsConnections();
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
    if (!isCoreTestTarget(target) ||
        timeout.inMilliseconds < 1 ||
        timeout.inMilliseconds > 32767) {
      throw ArgumentError('Delay requires HTTP(S) and a timeout of 1–32767ms');
    }
    if (target.scheme == 'http') {
      return withOutboundClient(outbound, (client) async {
        final watch = Stopwatch()..start();
        try {
          final request = await client.headUrl(target);
          request.followRedirects = false;
          await request.close();
          return watch.elapsed;
        } on SocketException {
          throw const CoreAdapterException('probe_failed');
        } on HttpException {
          throw const CoreAdapterException('probe_failed');
        }
      }, timeout: timeout);
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
  Future<CoreTelemetrySnapshot> pathTelemetry() {
    if (_closed) throw const CoreAdapterException('closed');
    return _pathTelemetry?.call() ?? telemetry();
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
  Future<T> withOutboundClients<T>(
    String outbound,
    Future<T> Function(CoreOutboundClients clients) action, {
    Duration timeout = const Duration(minutes: 2),
  }) async {
    _outboundHttp.checkOutbound(outbound);
    if (timeout <= Duration.zero || timeout > const Duration(minutes: 10)) {
      throw ArgumentError(
        'Probe timeout must be positive and at most 10 minutes',
      );
    }
    final deadline = Stopwatch()..start();
    final observed = await outbounds().timeout(
      timeout,
      onTimeout: () => throw const CoreAdapterException('timeout'),
    );
    final chain = await _resolvePinnedChain(outbound, observed);
    final remaining = timeout - deadline.elapsed;
    if (remaining <= Duration.zero) {
      throw const CoreAdapterException('timeout');
    }
    return _outboundHttp.withOutboundClients(
      chain.last,
      (clients) => action(
        CoreOutboundClients(chain: chain, createClient: clients.createClient),
      ),
      timeout: remaining,
    );
  }

  static Future<List<String>> _resolvePinnedChain(
    String outbound,
    List<CoreOutbound> observed,
  ) => Isolate.run(() => _pinnedChain(outbound, observed));

  static List<String> _pinnedChain(
    String outbound,
    List<CoreOutbound> observed,
  ) {
    final available = {for (final node in observed) node.name: node};
    final visited = <String>{};
    final chain = <String>[];
    var next = outbound;
    while (visited.add(next)) {
      final node = available[next];
      if (node == null) throw const CoreAdapterException('unknown_outbound');
      chain.add(next);
      if (node.members.isEmpty) {
        return chain;
      }
      final selected = node.selected;
      if (selected == null || !node.members.contains(selected)) {
        throw const CoreAdapterException('selection_unavailable');
      }
      next = selected;
    }
    throw const CoreAdapterException('outbound_cycle');
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _outboundHttp.close();
    _client.close(force: true);
    await Future.wait([for (final source in _logs.toList()) source.close()]);
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
