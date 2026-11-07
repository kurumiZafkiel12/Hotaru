import 'dart:convert';

import 'package:yaml/yaml.dart';

Object? decodeCoreYaml(
  String source, {
  int maxValues = 2000000,
  int maxExpandedBytes = 64 * 1024 * 1024,
  int maxDepth = 128,
}) {
  if (source.length > 16 * 1024 * 1024 ||
      utf8.encode(source).length > 16 * 1024 * 1024) {
    throw const FormatException('yaml_source_too_large');
  }
  if (maxValues < 1 || maxExpandedBytes < 1 || maxDepth < 1) {
    throw ArgumentError('Positive YAML limits required');
  }
  try {
    return _CoreYamlDecoder(
      maxValues,
      maxExpandedBytes,
      maxDepth,
    ).read(loadYamlNode(source), 0);
  } on StackOverflowError {
    throw const FormatException('yaml_depth_limit');
  }
}

final class _CoreYamlDecoder {
  int remainingValues;
  int remainingBytes;
  final int maxDepth;
  final Set<YamlNode> _visiting = Set.identity();

  _CoreYamlDecoder(this.remainingValues, this.remainingBytes, this.maxDepth);

  void _reserve(int bytes) {
    if (--remainingValues < 0) {
      throw const FormatException('yaml_expansion_limit');
    }
    _reserveBytes(bytes);
  }

  void _reserveBytes(int bytes) {
    if ((remainingBytes -= bytes) < 0) {
      throw const FormatException('yaml_expansion_limit');
    }
  }

  Object? read(YamlNode node, int depth, {String? key}) {
    if (depth > maxDepth) throw const FormatException('yaml_depth_limit');
    _reserve(32);
    if (node is YamlScalar) {
      final value = node.value;
      if (key == 'short-id' &&
          value is num &&
          node.style == ScalarStyle.PLAIN) {
        final literal = node.span.text.trim();
        if (RegExp(r'^[0-9a-fA-F]{1,16}$').hasMatch(literal)) {
          _reserveBytes(literal.length);
          return literal;
        }
      }
      if (value is String) _reserveBytes(utf8.encode(value).length);
      return value;
    }
    if (!_visiting.add(node)) throw const FormatException('yaml_alias_cycle');
    try {
      if (node is YamlList) {
        return [for (final item in node.nodes) read(item, depth + 1)];
      }
      if (node is! YamlMap) throw const FormatException('invalid_yaml_node');
      final result = <String, dynamic>{};
      final explicit = <String, YamlNode>{};
      YamlNode? merge;
      for (final entry in node.nodes.entries) {
        final key = entry.key;
        if (key is! YamlScalar || key.value is! String) {
          throw const FormatException('invalid_yaml_key');
        }
        _reserve(24 + utf8.encode(key.value as String).length);
        if (key.value == '<<' &&
            key.style == ScalarStyle.PLAIN &&
            key.span.text.trim() == '<<') {
          merge = entry.value;
        } else {
          explicit[key.value as String] = entry.value;
        }
      }
      if (merge != null) {
        final sources = merge is YamlList ? merge.nodes : [merge];
        for (final source in sources) {
          if (source is! YamlMap) {
            throw const FormatException('invalid_yaml_merge');
          }
          final inherited = read(source, depth + 1) as Map<String, dynamic>;
          for (final entry in inherited.entries) {
            result.putIfAbsent(entry.key, () => entry.value);
          }
        }
      }
      for (final entry in explicit.entries) {
        result[entry.key] = read(entry.value, depth + 1, key: entry.key);
      }
      return result;
    } finally {
      _visiting.remove(node);
    }
  }
}
