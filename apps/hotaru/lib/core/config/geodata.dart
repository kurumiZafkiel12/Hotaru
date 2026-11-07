import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:io' show InternetAddress;

import 'rule_set.dart';

enum CoreGeoKind { ip, site }

final class CoreGeoRequest {
  final CoreGeoKind kind;
  final String country;
  final List<String> attributes;
  final bool inverted;
  final String key;

  CoreGeoRequest._(
    this.kind,
    this.country,
    List<String> attributes,
    this.inverted,
  ) : attributes = List.unmodifiable(attributes),
      key =
          '${kind.name}:${inverted ? '!' : ''}$country${attributes.map((value) => '@$value').join()}';

  static CoreGeoRequest? parse(CoreGeoKind kind, String selector) {
    final value = selector.trim().toLowerCase();
    if (value.length > 256) return null;
    final inverted = value.startsWith('!');
    final parts = (inverted ? value.substring(1) : value).split('@');
    final country = parts.first.trim();
    final attrs = parts
        .skip(1)
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList();
    final valid = RegExp(r'^[a-z0-9_.!-]+$');
    if (country.isEmpty ||
        !valid.hasMatch(country) ||
        attrs.any((value) => !valid.hasMatch(value)) ||
        kind == CoreGeoKind.ip && attrs.isNotEmpty) {
      return null;
    }
    return CoreGeoRequest._(kind, country, attrs, inverted);
  }
}

final class CoreGeoMatchData {
  final CoreRuleSetSpec set;
  final bool inverted;

  const CoreGeoMatchData(this.set, this.inverted);
}

typedef CoreGeoResolver =
    Future<Map<String, CoreGeoMatchData>> Function(
      List<CoreGeoRequest> requests,
    );

final _lanSet = CoreRuleSetSpec(
  tag: 'geo:ip:lan',
  kind: CoreRuleSetKind.ipCidr,
  prefixes: const [
    '0.0.0.0/32',
    '10.0.0.0/8',
    '127.0.0.0/8',
    '169.254.0.0/16',
    '172.16.0.0/12',
    '192.168.0.0/16',
    '224.0.0.0/4',
    '::/128',
    '::1/128',
    'fc00::/7',
    'fe80::/10',
    'ff00::/8',
  ],
);

CoreGeoMatchData? builtinCoreGeoMatch(CoreGeoRequest request) =>
    request.kind == CoreGeoKind.ip &&
        request.country == 'lan' &&
        !request.inverted
    ? CoreGeoMatchData(_lanSet, false)
    : null;

final class CoreGeoDecoder {
  static const maxBytes = 64 * 1024 * 1024;
  static const maxEntries = CoreRuleSetSpec.maxEntries;

  static Future<Map<String, CoreGeoMatchData>> decode({
    required Uint8List bytes,
    required List<CoreGeoRequest> requests,
  }) => Isolate.run(() => decodeInWorker(bytes: bytes, requests: requests));

  static Map<String, CoreGeoMatchData> decodeInWorker({
    required Uint8List bytes,
    required List<CoreGeoRequest> requests,
  }) {
    if (bytes.length > maxBytes || requests.length > 1024) {
      throw const FormatException('geo_data_limit');
    }
    final index = <String, Uint8List>{};
    final reader = _Proto(bytes);
    while (!reader.done) {
      final (field, wire) = reader.key();
      if (field != 1) {
        reader.skip(wire);
        continue;
      }
      if (wire != 2 || index.length >= 10000) {
        throw const FormatException('invalid_geo_index');
      }
      final entry = reader.bytes();
      final fields = _Proto(entry);
      String? country;
      while (!fields.done) {
        final (field, wire) = fields.key();
        if (field == 1) {
          if (wire != 2 || country != null) {
            throw const FormatException('invalid_geo_country');
          }
          country = _text(fields, 256).toLowerCase();
        } else {
          fields.skip(wire);
        }
      }
      if (country == null || country.isEmpty || index.containsKey(country)) {
        throw const FormatException('invalid_geo_country');
      }
      index[country] = entry;
    }
    final result = <String, CoreGeoMatchData>{};
    var total = 0;
    for (final request in requests) {
      if (result.containsKey(request.key)) continue;
      final entry = index[request.country];
      if (entry == null) throw const FormatException('geo_country_unavailable');
      final decoded = _decodeEntry(entry, request);
      final set = decoded.set;
      total +=
          set.domains.length +
          set.suffixes.length +
          set.keywords.length +
          set.regexes.length +
          set.prefixes.length;
      if (total > maxEntries) throw const FormatException('geo_matcher_limit');
      result[request.key] = decoded;
    }
    return Map.unmodifiable(result);
  }
}

CoreGeoMatchData _decodeEntry(Uint8List bytes, CoreGeoRequest request) {
  final reader = _Proto(bytes);
  final domains = <String>{};
  final suffixes = <String>{};
  final keywords = <String>{};
  final regexes = <String>{};
  final prefixes = <String>{};
  var entries = 0;
  while (!reader.done) {
    final (field, wire) = reader.key();
    if (field == 2) {
      if (wire != 2 || ++entries > CoreGeoDecoder.maxEntries) {
        throw const FormatException('geo_matcher_limit');
      }
      final bytes = reader.bytes();
      if (request.kind == CoreGeoKind.ip) {
        prefixes.add(_prefix(bytes));
      } else {
        final domain = _domain(bytes);
        if (!request.attributes.every(domain.attributes.contains)) continue;
        switch (domain.type) {
          case 0:
            keywords.add(domain.value);
          case 1:
            regexes.add(domain.value);
          case 2:
            suffixes.add(domain.value.toLowerCase());
          case 3:
            domains.add(domain.value.toLowerCase());
          default:
            throw const FormatException('invalid_geo_domain_type');
        }
      }
    } else if (field == 3 && request.kind == CoreGeoKind.ip) {
      if (wire != 0) throw const FormatException('invalid_geo_reverse');
      // The source loader returns CIDRs only; reverse_match is not applied.
      reader.varint();
    } else {
      reader.skip(wire);
    }
  }
  return CoreGeoMatchData(
    CoreRuleSetSpec(
      tag: 'geo:${request.key}',
      kind: request.kind == CoreGeoKind.ip
          ? CoreRuleSetKind.ipCidr
          : CoreRuleSetKind.domain,
      domains: domains.toList(),
      suffixes: suffixes.toList(),
      keywords: keywords.toList(),
      regexes: regexes.toList(),
      prefixes: prefixes.toList(),
    ),
    request.inverted,
  );
}

String _prefix(Uint8List bytes) {
  final reader = _Proto(bytes);
  Uint8List? address;
  var prefix = 0;
  while (!reader.done) {
    final (field, wire) = reader.key();
    if (field == 1) {
      if (wire != 2 || address != null) {
        throw const FormatException('invalid_geo_address');
      }
      address = reader.bytes();
    } else if (field == 2) {
      if (wire != 0) throw const FormatException('invalid_geo_prefix');
      prefix = reader.varint();
    } else {
      reader.skip(wire);
    }
  }
  if (address == null ||
      ![4, 16].contains(address.length) ||
      prefix < 0 ||
      prefix > address.length * 8) {
    throw const FormatException('invalid_geo_prefix');
  }
  return '${InternetAddress.fromRawAddress(address).address}/$prefix';
}

({int type, String value, Set<String> attributes}) _domain(Uint8List bytes) {
  final reader = _Proto(bytes);
  var type = 0;
  String? value;
  final attributes = <String>{};
  var count = 0;
  while (!reader.done) {
    final (field, wire) = reader.key();
    if (field == 1) {
      if (wire != 0) throw const FormatException('invalid_geo_domain_type');
      type = reader.varint();
    } else if (field == 2) {
      if (wire != 2 || value != null) {
        throw const FormatException('invalid_geo_domain');
      }
      value = _text(reader, 65536);
    } else if (field == 3) {
      if (wire != 2 || ++count > 1024) {
        throw const FormatException('invalid_geo_attributes');
      }
      final attribute = _Proto(reader.bytes());
      while (!attribute.done) {
        final (field, wire) = attribute.key();
        if (field == 1) {
          if (wire != 2) throw const FormatException('invalid_geo_attribute');
          attributes.add(_text(attribute, 256).toLowerCase());
        } else {
          attribute.skip(wire);
        }
      }
    } else {
      reader.skip(wire);
    }
  }
  if (value == null || value.isEmpty) {
    throw const FormatException('invalid_geo_domain');
  }
  return (type: type, value: value, attributes: attributes);
}

String _text(_Proto reader, int maxLength) {
  final bytes = reader.bytes();
  if (bytes.length > maxLength * 4) {
    throw const FormatException('geo_text_limit');
  }
  final value = utf8.decode(bytes);
  if (value.length > maxLength) throw const FormatException('geo_text_limit');
  return value;
}

final class _Proto {
  final Uint8List data;
  int offset = 0;
  _Proto(this.data);
  bool get done => offset == data.length;

  int varint() {
    var value = 0;
    for (var shift = 0; shift <= 63; shift += 7) {
      if (offset >= data.length) {
        throw const FormatException('truncated_geo_varint');
      }
      final byte = data[offset++];
      if (shift == 63 && byte > 1) {
        throw const FormatException('invalid_geo_varint');
      }
      value |= (byte & 0x7f) << shift;
      if (byte & 0x80 == 0) return value;
    }
    throw const FormatException('invalid_geo_varint');
  }

  (int, int) key() {
    final key = varint();
    if (key < 8 || key > 0xffffffff) {
      throw const FormatException('invalid_geo_field');
    }
    return (key >> 3, key & 7);
  }

  Uint8List bytes() {
    final length = varint();
    if (length < 0 || length > data.length - offset) {
      throw const FormatException('truncated_geo_field');
    }
    final value = Uint8List.sublistView(data, offset, offset + length);
    offset += length;
    return value;
  }

  void skip(int wire) {
    switch (wire) {
      case 0:
        varint();
      case 1:
        advance(8);
      case 2:
        advance(varint());
      case 5:
        advance(4);
      default:
        throw const FormatException('unsupported_geo_wire');
    }
  }

  void advance(int length) {
    if (length < 0 || length > data.length - offset) {
      throw const FormatException('truncated_geo_field');
    }
    offset += length;
  }
}
