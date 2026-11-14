import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'adapter.dart';
import 'config/clash_rule_sets.dart';
import 'config/clash_subscription.dart';
import 'provider_download.dart';

final class CoreProviderCache {
  final String _root;
  final int maxEntries;
  final int maxBytes;
  Future<void> _writes = Future.value();

  CoreProviderCache._(this._root, this.maxEntries, this.maxBytes);

  static Future<CoreProviderCache> open(
    String directory, {
    int maxEntries = 256,
    int maxBytes = 64 * 1024 * 1024,
  }) async {
    if (!p.isAbsolute(directory) ||
        maxEntries < 1 ||
        maxEntries > 4096 ||
        maxBytes < 1024 ||
        maxBytes > 256 * 1024 * 1024) {
      throw ArgumentError('Invalid provider cache bounds');
    }
    final root = await Isolate.run(() async {
      final directoryFile = Directory(directory);
      await directoryFile.create(recursive: true);
      return directoryFile.resolveSymbolicLinks();
    });
    return CoreProviderCache._(root, maxEntries, maxBytes);
  }

  Future<CoreProviderPayload?> read(String key, int byteLimit) {
    _validate(key, byteLimit);
    final root = _root;
    return Isolate.run(() async {
      try {
        if (await Directory(root).resolveSymbolicLinks() != root) return null;
        final file = File(p.join(root, '$key.cache'));
        if (await FileSystemEntity.type(file.path, followLinks: false) !=
                FileSystemEntityType.file ||
            await file.resolveSymbolicLinks() != file.path) {
          return null;
        }
        final input = await file.open();
        final Uint8List bytes;
        try {
          if (await input.length() > byteLimit + 65546) return null;
          bytes = await input.read(byteLimit + 65547);
        } finally {
          await input.close();
        }
        if (bytes.length < 10 ||
            ascii.decode(bytes.sublist(0, 6), allowInvalid: true) !=
                'HTPC1\n') {
          return null;
        }
        final length = ByteData.sublistView(bytes, 6, 10).getUint32(0);
        if (length > 65536 || length > bytes.length - 10) return null;
        final metadata = jsonDecode(
          utf8.decode(bytes.sublist(10, 10 + length)),
        );
        final body = bytes.sublist(10 + length);
        if (metadata is! Map ||
            metadata['key'] != key ||
            body.length > byteLimit ||
            metadata['body'] != sha256.convert(body).toString()) {
          return null;
        }
        DateTime time(String name) {
          final value = DateTime.tryParse(metadata[name] as String);
          if (value == null || !value.isUtc) throw const FormatException();
          return value;
        }

        String? header(String name) {
          final value = metadata[name];
          if (value == null) return null;
          if (value is! String ||
              value.length > 8192 ||
              value.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
            throw const FormatException();
          }
          return value;
        }

        final target = header('url');
        final url = target == null ? null : Uri.tryParse(target);
        if (url != null &&
            (!const {'http', 'https'}.contains(url.scheme) ||
                url.host.isEmpty ||
                url.hasFragment ||
                url.userInfo.isNotEmpty)) {
          return null;
        }
        if (await file.resolveSymbolicLinks() != file.path) return null;
        return CoreProviderPayload(
          text: utf8.decode(body),
          fetchedAt: time('fetched'),
          validatedAt: metadata['validated'] == null ? null : time('validated'),
          finalUrl: url,
          etag: header('etag'),
          lastModified: header('modified'),
          subscriptionInfo: header('subscription'),
        );
      } catch (_) {
        return null;
      }
    });
  }

  Future<void> write(String key, CoreProviderPayload payload, int byteLimit) {
    _validate(key, byteLimit);
    final root = _root;
    final entriesLimit = maxEntries;
    final bytesLimit = maxBytes;
    final operation = _writes.then(
      (_) => Isolate.run(() async {
        if (await Directory(root).resolveSymbolicLinks() != root) {
          throw const CoreAdapterException('provider_cache_directory_changed');
        }
        final body = utf8.encode(payload.text);
        final metadata = utf8.encode(
          jsonEncode({
            'key': key,
            'body': sha256.convert(body).toString(),
            'fetched': payload.fetchedAt.toUtc().toIso8601String(),
            'validated': payload.validatedAt?.toUtc().toIso8601String(),
            'url': payload.finalUrl?.toString(),
            'etag': payload.etag,
            'modified': payload.lastModified,
            'subscription': payload.subscriptionInfo,
          }),
        );
        if (body.length > byteLimit ||
            metadata.length > 65536 ||
            body.length + metadata.length + 10 > bytesLimit) {
          throw const CoreAdapterException('provider_cache_entry_too_large');
        }
        final prefix = ByteData(4)..setUint32(0, metadata.length);
        final bytes = BytesBuilder(copy: false)
          ..add(ascii.encode('HTPC1\n'))
          ..add(prefix.buffer.asUint8List())
          ..add(metadata)
          ..add(body);
        final temporary = File(
          p.join(root, '.$key-${Random.secure().nextInt(1 << 32)}.tmp'),
        );
        try {
          await temporary.create(exclusive: true);
          await temporary.writeAsBytes(bytes.takeBytes(), flush: true);
          await temporary.rename(p.join(root, '$key.cache'));
        } finally {
          if (await temporary.exists()) await temporary.delete();
        }
        final cached = <(File, FileStat)>[];
        await for (final entry in Directory(root).list(followLinks: false)) {
          if (entry is File &&
              RegExp(
                r'^[a-f0-9]{64}\.cache$',
              ).hasMatch(p.basename(entry.path))) {
            final stat = await entry.stat();
            if (stat.type == FileSystemEntityType.file) {
              cached.add((entry, stat));
            }
          }
        }
        cached.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
        var total = cached.fold<int>(0, (sum, item) => sum + item.$2.size);
        var count = cached.length;
        for (final (file, stat) in cached) {
          if (count <= entriesLimit && total <= bytesLimit) break;
          await file.delete();
          total -= stat.size;
          count--;
        }
      }),
    );
    _writes = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  static void _validate(String key, int byteLimit) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(key) ||
        byteLimit < 1 ||
        byteLimit > 16 * 1024 * 1024) {
      throw ArgumentError('Invalid provider cache entry');
    }
  }
}

final class CoreCachedProviderLoader {
  final CoreProviderDownloader downloader;
  final CoreProviderCache cache;
  final DateTime Function() now;
  final Map<String, ({bool force, Future<CoreProviderPayload> future})>
  _pending = {};

  CoreCachedProviderLoader({
    required this.downloader,
    required this.cache,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;

  Future<CoreProviderPayload> loadProxy(
    CoreProxyProviderRequest request, {
    bool force = false,
  }) {
    if (request.kind == CoreProxyProviderKind.file) {
      return downloader.loadProxy(request);
    }
    return _load(
      'proxy',
      request.url,
      request.headers,
      request.outbound,
      request.interval,
      request.maxBytes,
      force,
      (cached) => downloader.loadProxy(request, cached: cached),
    );
  }

  Future<CoreProviderPayload> loadRule(
    CoreRuleProviderRequest request, {
    bool force = false,
  }) {
    if (request.url == null) return downloader.loadRule(request);
    return _load(
      'rule',
      request.url,
      const {},
      request.outbound,
      request.interval,
      request.maxBytes,
      force,
      (cached) => downloader.loadRule(request, cached: cached),
    );
  }

  Future<CoreProviderPayload> _load(
    String kind,
    Uri? url,
    Map<String, List<String>> headers,
    String? outbound,
    Duration interval,
    int maxBytes,
    bool force,
    Future<CoreProviderPayload> Function(CoreProviderPayload?) fetch,
  ) async {
    final userAgent = downloader.userAgent;
    final binding = downloader.outboundBindings[outbound];
    final key = await _providerCacheKey(
      kind,
      url,
      headers,
      outbound,
      binding,
      userAgent,
      maxBytes,
    );
    final pending = _pending[key];
    if (pending != null) {
      if (!force || pending.force) return pending.future;
      await pending.future.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      );
      return _load(
        kind,
        url,
        headers,
        outbound,
        interval,
        maxBytes,
        force,
        fetch,
      );
    }
    if (_pending.length >= 64) {
      throw const CoreAdapterException('provider_cache_busy');
    }
    final operation = () async {
      final cached = await cache.read(key, maxBytes);
      final age = cached == null
          ? null
          : now().toUtc().difference(cached.validatedAt ?? cached.fetchedAt);
      if (!force &&
          cached != null &&
          age != null &&
          !age.isNegative &&
          age < interval) {
        return cached;
      }
      final payload = await fetch(cached);
      await cache.write(key, payload, maxBytes);
      return payload;
    }();
    late final Future<CoreProviderPayload> tracked;
    tracked = operation.whenComplete(() {
      if (identical(_pending[key]?.future, tracked)) {
        final _ = _pending.remove(key);
      }
    });
    _pending[key] = (force: force, future: tracked);
    return tracked;
  }
}

Future<String> _providerCacheKey(
  String kind,
  Uri? url,
  Map<String, List<String>> headers,
  String? outbound,
  String? binding,
  String? userAgent,
  int maxBytes,
) => Isolate.run(() {
  final ordered = headers.keys.toList()..sort();
  return sha256
      .convert(
        utf8.encode(
          jsonEncode([
            kind,
            url?.toString(),
            [
              for (final name in ordered) [name, headers[name]],
            ],
            outbound,
            binding,
            userAgent,
            maxBytes,
          ]),
        ),
      )
      .toString();
});
