import 'dart:io';

abstract interface class CoreOutboundHttp {
  Future<T> withOutboundClient<T>(
    String outbound,
    Future<T> Function(HttpClient client) action, {
    Duration timeout = const Duration(minutes: 2),
  });
}
