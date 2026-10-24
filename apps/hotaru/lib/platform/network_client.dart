import 'dart:io';

/// External subscription/update requests follow the running local core.
/// Control API clients deliberately never use this factory.
HttpClient networkClient({
  int? proxyPort,
  Duration connectionTimeout = const Duration(seconds: 10),
}) {
  final client = HttpClient()..connectionTimeout = connectionTimeout;
  if (proxyPort != null) {
    if (proxyPort < 1024 || proxyPort > 65535) {
      throw ArgumentError('Invalid proxy port');
    }
    client.findProxy = (_) => 'PROXY 127.0.0.1:$proxyPort; DIRECT';
  }
  return client;
}
