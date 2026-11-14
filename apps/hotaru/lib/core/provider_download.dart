import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'adapter.dart';
import 'config/clash_rule_sets.dart';
import 'config/clash_subscription.dart';
import 'config/encoding.dart';
import 'provider_files.dart';
import 'routed_http.dart';

final class CoreProviderPayload {
  final String text;
  final DateTime fetchedAt;
  final DateTime? validatedAt;
  final Uri? finalUrl;
  final String? etag;
  final String? lastModified;
  final String? subscriptionInfo;

  const CoreProviderPayload({
    required this.text,
    required this.fetchedAt,
    this.validatedAt,
    this.finalUrl,
    this.etag,
    this.lastModified,
    this.subscriptionInfo,
  });
}

final class CoreProviderDownloader {
  final CoreRoutedHttp transport;
  final CoreProviderFileAccess? files;
  final String? userAgent;
  final Map<String, String> outboundBindings;

  CoreProviderDownloader({
    required this.transport,
    this.files,
    this.userAgent,
    Map<String, String> outboundBindings = const {},
  }) : outboundBindings = Map.unmodifiable(outboundBindings) {
    if (outboundBindings.length > 4096 ||
        outboundBindings.entries.any(
          (entry) => entry.key.isEmpty || entry.value.isEmpty,
        )) {
      throw ArgumentError('Invalid provider outbound bindings');
    }
  }

  Future<String> resolveProxy(CoreProxyProviderRequest request) async =>
      (await loadProxy(request)).text;

  Future<String> resolveRule(CoreRuleProviderRequest request) async =>
      (await loadRule(request)).text;

  Future<CoreProviderPayload> loadProxy(
    CoreProxyProviderRequest request, {
    CoreProviderPayload? cached,
  }) => _guard(
    () => request.kind == CoreProxyProviderKind.file
        ? _file(request.path, request.maxBytes, request.timeout)
        : _http(
            request.url,
            request.headers,
            request.outbound,
            request.maxBytes,
            request.timeout,
            cached: cached,
          ),
  );

  Future<CoreProviderPayload> loadRule(
    CoreRuleProviderRequest request, {
    CoreProviderPayload? cached,
  }) => _guard(
    () => request.url == null
        ? _file(request.path, request.maxBytes, request.timeout)
        : _http(
            request.url,
            const {},
            request.outbound,
            request.maxBytes,
            request.timeout,
            cached: cached,
          ),
  );

  Future<CoreProviderPayload> _guard(
    Future<CoreProviderPayload> Function() operation,
  ) async {
    try {
      return await operation();
    } on CoreAdapterException {
      rethrow;
    } on CoreConfigSizeException {
      rethrow;
    } on TimeoutException {
      throw const CoreAdapterException('timeout');
    } on FormatException {
      throw const CoreAdapterException('invalid_provider_encoding');
    } catch (_) {
      throw const CoreAdapterException('provider_transport');
    }
  }

  Future<CoreProviderPayload> _file(
    String? reference,
    int maxBytes,
    Duration timeout,
  ) async {
    final access = files;
    if (access == null || reference == null) {
      throw const CoreAdapterException('provider_file_not_authorized');
    }
    return CoreProviderPayload(
      text: await access.read(reference, maxBytes: maxBytes, timeout: timeout),
      fetchedAt: DateTime.now().toUtc(),
    );
  }

  Future<CoreProviderPayload> _http(
    Uri? url,
    Map<String, List<String>> headers,
    String? sourceOutbound,
    int maxBytes,
    Duration timeout, {
    CoreProviderPayload? cached,
  }) async {
    if (url == null ||
        maxBytes < 1 ||
        maxBytes > CoreConfigEncoding.maxBytes ||
        timeout <= Duration.zero) {
      throw const CoreAdapterException('invalid_provider_request');
    }
    final outbound = sourceOutbound == null || sourceOutbound == 'DIRECT'
        ? sourceOutbound
        : outboundBindings[sourceOutbound];
    if (sourceOutbound != null &&
        sourceOutbound != 'DIRECT' &&
        outbound == null) {
      throw const CoreAdapterException('provider_route_binding_required');
    }
    if (cached != null) {
      await _validateCachedPayload(cached, maxBytes);
    }
    final agent = userAgent;
    final prepared = await Isolate.run(
      () => _ProviderRequest.prepare(url, headers, agent),
    );
    return transport.withRoutedClient(
      (client) async {
        var target = prepared.url;
        var requestHeaders = prepared.headers;
        for (var redirects = 0; ; redirects++) {
          final request = await client.getUrl(target);
          request.followRedirects = false;
          requestHeaders.forEach(
            (key, values) => request.headers.set(key, values),
          );
          final conditional =
              cached != null &&
              target == cached.finalUrl &&
              (cached.etag != null || cached.lastModified != null);
          if (conditional) {
            if (cached.etag case final value?) {
              request.headers.set(HttpHeaders.ifNoneMatchHeader, value);
            }
            if (cached.lastModified case final value?) {
              request.headers.set(HttpHeaders.ifModifiedSinceHeader, value);
            }
          }
          final response = await request.close();
          if (response.statusCode == HttpStatus.notModified && conditional) {
            await response.listen((_) {}, onError: (Object _) {}).cancel();
            return CoreProviderPayload(
              text: cached.text,
              fetchedAt: cached.fetchedAt,
              validatedAt: DateTime.now().toUtc(),
              finalUrl: cached.finalUrl,
              etag: cached.etag,
              lastModified: cached.lastModified,
              subscriptionInfo: cached.subscriptionInfo,
            );
          }
          if (const {301, 302, 303, 307, 308}.contains(response.statusCode)) {
            final location = response.headers.value(HttpHeaders.locationHeader);
            await response.listen((_) {}, onError: (Object _) {}).cancel();
            if (location == null || redirects >= 10) {
              throw const CoreAdapterException('invalid_provider_redirect');
            }
            final next = target.resolve(location).removeFragment();
            _ProviderRequest.validateUrl(next);
            if (next.userInfo.isNotEmpty ||
                target.scheme == 'https' && next.scheme != 'https') {
              throw const CoreAdapterException('unsafe_provider_redirect');
            }
            if (next.origin != target.origin) {
              requestHeaders = {
                for (final entry in requestHeaders.entries)
                  if (!const {
                    'authorization',
                    'cookie',
                    'cookie2',
                    'proxy-authorization',
                    'host',
                  }.contains(entry.key))
                    entry.key: entry.value,
              };
            }
            target = next;
            continue;
          }
          if (response.statusCode != HttpStatus.ok) {
            final status = response.statusCode;
            await response.listen((_) {}, onError: (Object _) {}).cancel();
            throw CoreAdapterException('provider_http', status: status);
          }
          String? header(String name) {
            final value = response.headers[name]?.firstOrNull;
            if (value != null && value.length > 8192) {
              throw const CoreAdapterException('provider_header_too_large');
            }
            return value;
          }

          final etag = header(HttpHeaders.etagHeader);
          final modified = header(HttpHeaders.lastModifiedHeader);
          final info = header('subscription-userinfo');
          final bytes = BytesBuilder(copy: false);
          await for (final chunk in response) {
            if (bytes.length + chunk.length > maxBytes) {
              throw const CoreConfigSizeException();
            }
            bytes.add(chunk);
          }
          final payload = bytes.takeBytes();
          final text = await _decode(payload);
          return CoreProviderPayload(
            text: text,
            fetchedAt: DateTime.now().toUtc(),
            finalUrl: target,
            etag: etag,
            lastModified: modified,
            subscriptionInfo: info,
          );
        }
      },
      outbound: outbound,
      timeout: timeout,
    );
  }
}

final class _ProviderRequest {
  final Uri url;
  final Map<String, List<String>> headers;

  const _ProviderRequest(this.url, this.headers);

  static void validateUrl(Uri url) {
    if (!const {'http', 'https'}.contains(url.scheme) ||
        url.host.isEmpty ||
        url.hasFragment ||
        url.toString().length > 8192) {
      throw const CoreAdapterException('invalid_provider_url');
    }
  }

  static _ProviderRequest prepare(
    Uri url,
    Map<String, List<String>> source,
    String? userAgent,
  ) {
    validateUrl(url);
    if (source.length > 64) {
      throw const CoreAdapterException('invalid_provider_headers');
    }
    CoreConfigEncoding.encode(source, byteLimit: 64 * 1024);
    final headers = <String, List<String>>{};
    final name = RegExp(r"^[!#$%&'*+.^_`|~0-9a-z-]+$");
    for (final entry in source.entries) {
      final key = entry.key.toLowerCase();
      if (key.length > 128 ||
          !name.hasMatch(key) ||
          headers.containsKey(key) ||
          const {
            'proxy-authorization',
            'connection',
            'transfer-encoding',
            'content-length',
            'upgrade',
          }.contains(key) ||
          entry.value.length > 16 ||
          entry.value.any(
            (value) =>
                value.length > 8192 ||
                value.contains(RegExp(r'[\x00-\x08\x0a-\x1f\x7f]')),
          )) {
        throw const CoreAdapterException('invalid_provider_headers');
      }
      headers[key] = List.unmodifiable(entry.value);
    }
    if (userAgent != null && !headers.containsKey('user-agent')) {
      if (userAgent.length > 8192 ||
          userAgent.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
        throw const CoreAdapterException('invalid_provider_headers');
      }
      headers['user-agent'] = [userAgent];
    }
    if (url.userInfo.isNotEmpty) {
      final split = url.userInfo.indexOf(':');
      final user = Uri.decodeComponent(
        split < 0 ? url.userInfo : url.userInfo.substring(0, split),
      );
      final password = split < 0
          ? ''
          : Uri.decodeComponent(url.userInfo.substring(split + 1));
      if (user.contains(':') ||
          '$user$password'.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
        throw const CoreAdapterException('invalid_provider_url');
      }
      headers['authorization'] = [
        'Basic ${base64Encode(utf8.encode('$user:$password'))}',
      ];
    }
    return _ProviderRequest(
      url.replace(userInfo: ''),
      Map.unmodifiable(headers),
    );
  }
}

Future<String> _decode(Uint8List bytes) =>
    Isolate.run(() => utf8.decode(bytes));

Future<void> _validateCachedPayload(CoreProviderPayload cached, int maxBytes) =>
    Isolate.run(() {
      if (utf8.encode(cached.text).length > maxBytes ||
          [cached.etag, cached.lastModified].any(
            (value) =>
                value != null &&
                (value.length > 8192 ||
                    value.contains(RegExp(r'[\x00-\x1f\x7f]'))),
          )) {
        throw const CoreAdapterException('invalid_cached_provider');
      }
    });
