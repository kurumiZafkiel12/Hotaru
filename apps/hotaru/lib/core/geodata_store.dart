import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'adapter.dart';
import 'config/geodata.dart';
import 'geodata_files.dart';
import 'routed_http.dart';

abstract interface class CoreGeoResources {
  Set<String> get supportedTypes;
  Future<String?> filePath(String type);
}

const coreGeoDefaultUrls = {
  'geoip':
      'https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.dat',
  'geosite':
      'https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat',
};

final class CoreGeoDataStore {
  final String home;
  final CoreRoutedHttp transport;
  final _pending = <String, Future<Uint8List>>{};
  Future<void> _files = Future.value();

  CoreGeoDataStore({required this.home, required this.transport});

  Future<String> path(String type, Map<String, String> urls) async {
    final key = type.toLowerCase();
    final url = _url(key, urls);
    final file = await _cachePath(key, url);
    if (await FileSystemEntity.type(file, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const CoreAdapterException('unsafe_geo_path');
    }
    if (await FileSystemEntity.type(file, followLinks: false) ==
        FileSystemEntityType.file) {
      return file;
    }
    if (url == coreGeoDefaultUrls[key]) {
      final legacy = p.join(home, key == 'geoip' ? 'GeoIP.dat' : 'GeoSite.dat');
      if (await FileSystemEntity.type(legacy, followLinks: false) ==
          FileSystemEntityType.file) {
        return legacy;
      }
    }
    return file;
  }

  Future<Map<String, CoreGeoMatchData>> resolve(
    List<CoreGeoRequest> requests, {
    Map<String, String> urls = const {},
  }) async {
    if (requests.length > 1024) {
      throw const FormatException('geo_request_limit');
    }
    final result = <String, CoreGeoMatchData>{};
    for (final kind in CoreGeoKind.values) {
      final selected = <CoreGeoRequest>[];
      for (final request in requests.where((request) => request.kind == kind)) {
        final builtin = builtinCoreGeoMatch(request);
        if (builtin != null) {
          result[request.key] = builtin;
        } else {
          selected.add(request);
        }
      }
      if (selected.isEmpty) continue;
      final type = kind == CoreGeoKind.ip ? 'geoip' : 'geosite';
      final cached = await _withFiles(() async {
        final file = await path(type, urls);
        if (!await File(file).exists()) return null;
        return CoreGeoDataFiles(
          geoIpPath: kind == CoreGeoKind.ip ? file : null,
          geoSitePath: kind == CoreGeoKind.site ? file : null,
        ).resolve(selected);
      });
      result.addAll(
        cached ??
            await CoreGeoDecoder.decode(
              bytes: await _load(type, urls: urls, requests: selected),
              requests: selected,
            ),
      );
    }
    return Map.unmodifiable(result);
  }

  Future<void> update(
    String type, {
    Map<String, String> urls = const {},
    List<CoreGeoRequest> requests = const [],
  }) async {
    await _load(type, urls: urls, requests: requests);
  }

  Future<Uint8List> _load(
    String type, {
    required Map<String, String> urls,
    required List<CoreGeoRequest> requests,
  }) async {
    final key = type.toLowerCase();
    final url = _url(key, urls);
    final target = await _cachePath(key, url);
    if (!_pending.containsKey(target) && _pending.length >= 4) {
      throw const CoreAdapterException('geo_queue_full');
    }
    final operation = _pending[target] ??= _download(url, target, requests);
    try {
      return await operation;
    } finally {
      if (identical(_pending[target], operation)) {
        _pending.remove(target)?.ignore();
      }
    }
  }

  String _url(String type, Map<String, String> urls) {
    if (!coreGeoDefaultUrls.containsKey(type)) {
      throw const CoreAdapterException('unsupported_geo_resource');
    }
    final url = urls[type] ?? coreGeoDefaultUrls[type]!;
    final uri = Uri.tryParse(url);
    if (url.length > 8192 ||
        uri == null ||
        !const {'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      throw const CoreAdapterException('invalid_geo_url');
    }
    return url;
  }

  Future<String> _cachePath(String type, String url) async {
    final homeRoot = await Directory(home).resolveSymbolicLinks();
    var root = homeRoot;
    for (final segment in ['providers', 'sing-box', 'geodata']) {
      final directory = Directory(p.join(root, segment));
      await directory.create();
      root = await directory.resolveSymbolicLinks();
      if (!p.isWithin(homeRoot, root)) {
        throw const CoreAdapterException('unsafe_geo_path');
      }
    }
    final name = sha256.convert(utf8.encode('$type\n$url')).toString();
    return p.join(root, '$name.dat');
  }

  Future<Uint8List> _download(
    String url,
    String target,
    List<CoreGeoRequest> requests,
  ) async {
    if (await FileSystemEntity.type(target, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const CoreAdapterException('unsafe_geo_path');
    }
    final bytes = await transport.withRoutedClient((client) async {
      var uri = Uri.parse(url);
      for (var redirects = 0; ; redirects++) {
        final request = await client.getUrl(uri);
        request.followRedirects = false;
        final response = await request.close();
        final location = response.headers.value('location');
        if (const {301, 302, 303, 307, 308}.contains(response.statusCode) &&
            location != null) {
          await response.listen((_) {}, onError: (Object _) {}).cancel();
          if (redirects >= 8) {
            throw const CoreAdapterException('geo_redirect_limit');
          }
          final next = uri.resolve(location);
          _url('geoip', {'geoip': next.toString()});
          if (uri.scheme == 'https' && next.scheme != 'https') {
            throw const CoreAdapterException('unsafe_geo_redirect');
          }
          uri = next;
          continue;
        }
        if (response.statusCode != 200 ||
            response.contentLength > CoreGeoDecoder.maxBytes) {
          await response.listen((_) {}, onError: (Object _) {}).cancel();
          throw const CoreAdapterException('geo_download_failed');
        }
        final buffer = BytesBuilder(copy: false);
        var size = 0;
        await for (final chunk in response) {
          size += chunk.length;
          if (size > CoreGeoDecoder.maxBytes) {
            throw const CoreAdapterException('geo_data_limit');
          }
          buffer.add(chunk);
        }
        return buffer.takeBytes();
      }
    }, timeout: const Duration(minutes: 2));
    await CoreGeoDecoder.decode(bytes: bytes, requests: requests);
    await _withFiles(
      () => _writeGeoCache(bytes, target, {..._pending.keys, target}),
    );
    return bytes;
  }

  Future<T> _withFiles<T>(Future<T> Function() action) {
    final operation = _files.then((_) => action());
    _files = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }
}

Future<void> _writeGeoCache(
  Uint8List bytes,
  String destination,
  Set<String> protected,
) {
  return Isolate.run(() async {
    final stage = await Directory(p.dirname(destination)).createTemp('.geo-');
    try {
      final file = await File(
        p.join(stage.path, 'payload'),
      ).writeAsBytes(bytes, flush: true);
      if (await FileSystemEntity.type(destination, followLinks: false) ==
          FileSystemEntityType.link) {
        throw const CoreAdapterException('unsafe_geo_path');
      }
      await file.rename(destination);
      final entries = <({File file, int size, DateTime modified})>[];
      await for (final entry in Directory(
        p.dirname(destination),
      ).list(followLinks: false)) {
        if (entry is! File ||
            !RegExp(r'^[0-9a-f]{64}\.dat$').hasMatch(p.basename(entry.path))) {
          continue;
        }
        final stat = await entry.stat();
        entries.add((file: entry, size: stat.size, modified: stat.modified));
      }
      entries.sort((a, b) => a.modified.compareTo(b.modified));
      var total = entries.fold<int>(0, (sum, entry) => sum + entry.size);
      var count = entries.length;
      for (final entry in entries) {
        if (count <= 8 && total <= 128 * 1024 * 1024) break;
        if (protected.contains(entry.file.path)) continue;
        await entry.file.delete();
        count--;
        total -= entry.size;
      }
    } finally {
      await stage.delete(recursive: true);
    }
  });
}
