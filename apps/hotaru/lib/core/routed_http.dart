import 'dart:io';

abstract interface class CoreRoutedHttp {
  Future<T> withRoutedClient<T>(
    Future<T> Function(HttpClient client) action, {
    String? outbound,
    Duration timeout = const Duration(minutes: 2),
  });
}
