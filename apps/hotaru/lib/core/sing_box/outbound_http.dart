import 'dart:io';

import '../adapter.dart';
import '../config/probe_listener.dart';
import '../outbound_http.dart';

final class SingBoxOutboundHttp implements CoreOutboundHttp {
  final CoreProbeListenerSpec? listener;
  final Set<String> _outbounds;
  final Set<HttpClient> _clients = {};
  bool _closed = false;

  SingBoxOutboundHttp({
    required this.listener,
    required Iterable<String> outbounds,
  }) : _outbounds = Set.unmodifiable(outbounds) {
    if (listener != null && !listener!.isValid) {
      throw ArgumentError('Invalid owned probe listener');
    }
  }

  @override
  Future<T> withOutboundClient<T>(
    String outbound,
    Future<T> Function(HttpClient client) action, {
    Duration timeout = const Duration(minutes: 2),
  }) async {
    if (_closed) throw const CoreAdapterException('closed');
    final probe = listener;
    if (probe == null) {
      throw const CoreAdapterException('outbound_http_unavailable');
    }
    if (!_outbounds.contains(outbound)) {
      throw const CoreAdapterException('unknown_outbound');
    }
    if (timeout <= Duration.zero || timeout > const Duration(minutes: 10)) {
      throw ArgumentError(
        'Probe timeout must be positive and at most 10 minutes',
      );
    }
    final client = HttpClient()
      ..findProxy = ((_) => 'PROXY 127.0.0.1:${probe.port}')
      ..connectionTimeout = const Duration(seconds: 10);
    // The pinned engine's 407 challenge is rejected by Dart's parser.
    // Register credentials for this exact loopback proxy before the first request.
    client.addProxyCredentials(
      '127.0.0.1',
      probe.port,
      'sing-box',
      HttpClientBasicCredentials(
        CoreProbeListenerSpec.username(outbound),
        probe.secret,
      ),
    );
    _clients.add(client);
    try {
      final result = await action(client).timeout(
        timeout,
        onTimeout: () => throw const CoreAdapterException('timeout'),
      );
      if (_closed) throw const CoreAdapterException('closed');
      return result;
    } finally {
      _clients.remove(client);
      client.close(force: true);
    }
  }

  void close() {
    _closed = true;
    for (final client in _clients) {
      client.close(force: true);
    }
    _clients.clear();
  }
}
