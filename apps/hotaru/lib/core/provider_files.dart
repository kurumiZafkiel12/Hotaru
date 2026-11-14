import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'config/encoding.dart';

final class CoreProviderFileAccess {
  final String _root;
  final Map<String, String> _canonical;
  final Map<String, String> paths;

  CoreProviderFileAccess._(
    this._root,
    Map<String, String> canonical,
    Map<String, String> paths,
  ) : _canonical = Map.unmodifiable(canonical),
      paths = Map.unmodifiable(paths);

  static Future<CoreProviderFileAccess> authorize({
    required String root,
    required Map<String, String> files,
  }) {
    final requested = Map<String, String>.of(files);
    return Isolate.run(() async {
      if (requested.length > 4096) {
        throw const FormatException('provider_file_grant_limit');
      }
      final directory = await Directory(root).resolveSymbolicLinks();
      final canonical = <String, String>{};
      final paths = <String, String>{};
      final aliases = <String>{};
      for (final entry in requested.entries) {
        if (!RegExp(r'^hotaru-files/[a-z0-9_-]{1,128}$').hasMatch(entry.key) ||
            !p.isAbsolute(entry.value)) {
          throw const FormatException('invalid_provider_file_grant');
        }
        final path = p.normalize(entry.value);
        final resolved = await File(path).resolveSymbolicLinks();
        if (!p.isWithin(directory, resolved) ||
            !aliases.add(path) ||
            (await File(resolved).stat()).type != FileSystemEntityType.file) {
          throw const FormatException('provider_file_outside_grant');
        }
        canonical[entry.key] = resolved;
        paths[entry.key] = path;
      }
      return CoreProviderFileAccess._(directory, canonical, paths);
    });
  }

  Future<String> read(
    String reference, {
    required int maxBytes,
    required Duration timeout,
  }) {
    if (maxBytes < 1 ||
        maxBytes > CoreConfigEncoding.maxBytes ||
        timeout <= Duration.zero) {
      throw ArgumentError('Invalid provider file read bounds');
    }
    final path = _canonical[reference];
    final root = _root;
    if (path == null) {
      return Future.error(
        const FormatException('provider_file_not_authorized'),
      );
    }
    return Isolate.run(() async {
      final watch = Stopwatch()..start();
      final resolved = await File(path).resolveSymbolicLinks();
      if (resolved != path ||
          !p.isWithin(root, resolved) ||
          (await File(resolved).stat()).type != FileSystemEntityType.file) {
        throw const FormatException('provider_file_grant_changed');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in File(resolved).openRead().timeout(timeout)) {
        if (watch.elapsed >= timeout) {
          throw TimeoutException('Provider file read timed out');
        }
        if (bytes.length + chunk.length > maxBytes) {
          throw const CoreConfigSizeException();
        }
        bytes.add(chunk);
      }
      return utf8.decode(bytes.takeBytes());
    });
  }
}
