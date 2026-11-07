import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../models/models.dart';
import 'config/encoding.dart';
import 'config/yaml_document.dart';

abstract interface class CoreProfileTextBuilder {
  Future<String> buildProfileText(SetupBase base);
}

final class CoreProfileDocuments {
  static Future<Map<String, dynamic>> read(String path) =>
      Isolate.run(() async => _mapping(await _readBytes(path)));

  static Future<ProfileBase> base(String path) => Isolate.run(() async {
    final bytes = await _readBytes(path);
    final document = _mapping(bytes);
    final proxies = _mappings(document, 'proxies');
    final groups = _mappings(document, 'proxy-groups');
    final rules = _rules(document['rules']);
    final config = Map<String, dynamic>.from(document)
      ..remove('proxies')
      ..remove('proxy-groups')
      ..remove('rules')
      ..remove('sub-rules');
    return ProfileBase(
      config: config,
      digest: sha256.convert(bytes).toString(),
      proxies: proxies.length,
      proxyGroups: groups.length,
      rules: rules.length,
      matchRules: [
        for (final rule in rules)
          if (rule.split(',').first.trim().toUpperCase() == 'MATCH') rule,
      ],
    );
  });

  static Future<Map<String, dynamic>> outbounds(String path) => Isolate.run(
    () async {
      final document = _mapping(await _readBytes(path));
      return {
        for (final key in ['proxies', 'proxy-groups'])
          key: [
            for (final entry in _mappings(document, key))
              {'name': _string(entry['name']), 'type': _string(entry['type'])},
          ],
      };
    },
  );

  static Future<String> build(SetupBase base) {
    final path = base.path;
    final overlay = base.overlay;
    return Isolate.run(() async {
      final source = _mapping(await _readBytes(path));
      final result = _mapping(utf8.encode(overlay));
      for (final key in ['proxies', 'proxy-groups', 'sub-rules']) {
        if (source.containsKey(key)) result[key] = source[key];
      }
      if (source.containsKey('rules')) {
        final added = _rules(result['rules']);
        final original = _rules(source['rules']);
        result['rules'] = [...added, ...original];
      } else {
        _rules(result['rules']);
      }
      return utf8.decode(CoreConfigEncoding.encode(result));
    });
  }
}

Future<Uint8List> _readBytes(String path) async {
  final bytes = BytesBuilder(copy: false);
  var length = 0;
  await for (final chunk in File(path).openRead()) {
    length += chunk.length;
    if (length > CoreConfigEncoding.maxBytes) {
      throw const CoreConfigSizeException();
    }
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}

Map<String, dynamic> _mapping(List<int> bytes) {
  if (bytes.length > CoreConfigEncoding.maxBytes) {
    throw const CoreConfigSizeException();
  }
  final text = utf8.decode(bytes);
  if (text.startsWith('age-encryption.org/v1') ||
      text.startsWith('-----BEGIN AGE ENCRYPTED FILE-----')) {
    throw const FormatException('encrypted_profile_requires_decryption');
  }
  final value = decodeCoreYaml(text);
  if (value == null) return {};
  if (value is! Map<String, dynamic>) {
    throw const FormatException('profile_mapping_required');
  }
  return value;
}

List<Map<String, dynamic>> _mappings(
  Map<String, dynamic> document,
  String key,
) {
  final value = document[key];
  if (value == null) return [];
  if (value is! List || value.any((item) => item is! Map<String, dynamic>)) {
    throw FormatException('invalid_profile_section:$key');
  }
  return value.cast<Map<String, dynamic>>();
}

List<String> _rules(Object? value) {
  if (value == null) return [];
  if (value is! List || value.any((item) => item is! String)) {
    throw const FormatException('invalid_profile_rules');
  }
  return value.cast<String>();
}

String _string(Object? value) {
  if (value is! String) throw const FormatException('invalid_outbound_field');
  return value;
}
