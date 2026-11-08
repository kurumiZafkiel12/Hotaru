import 'dart:io';

abstract interface class CoreOutboundHttp {
  Future<T> withOutboundClient<T>(
    String outbound,
    Future<T> Function(HttpClient client) action, {
    Duration timeout = const Duration(minutes: 2),
  });
}

final class CoreOutboundClients {
  final List<String> chain;
  final HttpClient Function() createClient;

  CoreOutboundClients({required List<String> chain, required this.createClient})
    : chain = List.unmodifiable(chain);
}

abstract interface class CoreOutboundHttpClients implements CoreOutboundHttp {
  Future<T> withOutboundClients<T>(
    String outbound,
    Future<T> Function(CoreOutboundClients clients) action, {
    Duration timeout = const Duration(minutes: 2),
  });
}
