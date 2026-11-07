import 'dart:convert';
import 'dart:isolate';

import 'clash_importer.dart';
import 'encoding.dart';
import 'profile.dart';

final class CoreShareLinkBatch {
  final List<Map<String, dynamic>> nodes;
  final List<CoreConfigIssue> issues;

  CoreShareLinkBatch(
    List<Map<String, dynamic>> nodes,
    List<CoreConfigIssue> issues,
  ) : nodes = List.unmodifiable(nodes),
      issues = List.unmodifiable(issues);
}

final class CoreShareLinks {
  static Future<CoreShareLinkBatch> decode(String source) =>
      Isolate.run(() => _decode(source));

  static Future<List<CoreShareLinkBatch>> decodeMany(List<String> sources) =>
      Isolate.run(() {
        var bytes = 0;
        if (sources.length > 100000) throw const CoreConfigSizeException();
        for (final source in sources) {
          if (source.length > CoreConfigEncoding.maxBytes) {
            throw const CoreConfigSizeException();
          }
          bytes += utf8.encode(source).length;
          if (bytes > CoreConfigEncoding.maxBytes) {
            throw const CoreConfigSizeException();
          }
        }
        return [for (final source in sources) _decode(source)];
      });

  static Future<CoreConfigImportResult> import(String source) =>
      Isolate.run(() async {
        final decoded = _decode(source);
        if (decoded.issues.isNotEmpty) {
          return CoreConfigImportResult(issues: decoded.issues);
        }
        final names = decoded.nodes.map((node) => node['name']).toSet();
        var group = 'Hotaru Imported';
        for (var index = 1; names.contains(group); index++) {
          group = 'Hotaru Imported ($index)';
        }
        return ClashProfileImporter().importDocument({
          'proxies': decoded.nodes,
          'proxy-groups': [
            {'name': group, 'type': 'select', 'proxies': names.toList()},
          ],
          'rules': ['MATCH,$group'],
        });
      });
}

CoreShareLinkBatch _decode(String source) {
  final issues = <CoreConfigIssue>[];
  final nodes = <Map<String, dynamic>>[];
  if (source.length > CoreConfigEncoding.maxBytes ||
      utf8.encode(source).length > CoreConfigEncoding.maxBytes) {
    return CoreShareLinkBatch([], [
      const CoreConfigIssue('share_source_too_large', 'input'),
    ]);
  }
  var text = source.trim();
  if (!text.contains('://') && text.isNotEmpty) {
    try {
      text = _base64Text(text.replaceAll(RegExp(r'\s'), ''));
    } on FormatException {
      return CoreShareLinkBatch([], [
        const CoreConfigIssue('invalid_share_encoding', 'input'),
      ]);
    }
  }
  final lines = const LineSplitter().convert(text);
  if (lines.length > 100000) {
    return CoreShareLinkBatch([], [
      const CoreConfigIssue('too_many_share_links', 'input'),
    ]);
  }
  for (var index = 0; index < lines.length; index++) {
    final line = lines[index].trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    try {
      if (line.length > 65536 || utf8.encode(line).length > 65536) {
        throw const FormatException();
      }
      nodes.add(_link(line));
    } on _ShareFailure catch (failure) {
      issues.add(
        CoreConfigIssue(failure.code, 'lines.$index.${failure.field}'),
      );
    } on FormatException {
      issues.add(
        CoreConfigIssue('invalid_or_unsupported_share_link', 'lines.$index'),
      );
    }
  }
  if (nodes.isEmpty && issues.isEmpty) {
    issues.add(const CoreConfigIssue('empty_share_links', 'input'));
  }
  return CoreShareLinkBatch(issues.isEmpty ? nodes : [], issues);
}

String _base64Text(String value) =>
    utf8.decode(base64.decode(base64.normalize(value)));

final class _ShareFailure implements Exception {
  final String code;
  final String field;
  const _ShareFailure(this.code, this.field);
}

Map<String, dynamic> _link(String source) {
  final prefix = source.split('://').first.toLowerCase();
  if (prefix == 'vmess') return _vmess(source.substring(8));
  if (prefix == 'ss') return _shadowsocks(source);
  final uri = Uri.parse(source);
  final type = switch (uri.scheme) {
    'http' || 'https' => 'http',
    'socks' || 'socks5' => 'socks5',
    'vless' => 'vless',
    'trojan' => 'trojan',
    'hy2' || 'hysteria2' => 'hysteria2',
    'tuic' => 'tuic',
    _ => throw const _ShareFailure('unsupported_share_protocol', 'scheme'),
  };
  final authority = source
      .substring(source.indexOf('://') + 3)
      .split(RegExp(r'[/#?]'))
      .first;
  final explicitPort = RegExp(r':([0-9]+)$').firstMatch(authority)?.group(1);
  final port = explicitPort != null
      ? int.parse(explicitPort)
      : uri.hasPort
      ? uri.port
      : switch (uri.scheme) {
          'http' => 80,
          'socks' || 'socks5' => 1080,
          _ => 443,
        };
  final node = _endpoint(uri, type, port);
  final query = _query(uri);
  final allowed = <String>{};
  final auth = Uri.decodeComponent(uri.userInfo);
  if (type == 'http' || type == 'socks5') {
    if (uri.userInfo.isNotEmpty) {
      final split = uri.userInfo.indexOf(':');
      node['username'] = Uri.decodeComponent(
        split < 0 ? uri.userInfo : uri.userInfo.substring(0, split),
      );
      node['password'] = split < 0
          ? ''
          : Uri.decodeComponent(uri.userInfo.substring(split + 1));
    }
    if (uri.scheme == 'https') node['tls'] = true;
  } else if (type == 'vless') {
    node['uuid'] = auth;
    allowed.addAll(['security', 'encryption', 'flow', 'pbk', 'sid']);
    if (query['flow'] case final value?) node['flow'] = value;
    if (query['encryption'] case final value?) node['encryption'] = value;
    final security = query['security'] ?? 'none';
    if (!const ['none', 'tls', 'reality'].contains(security)) {
      throw const FormatException();
    }
    node['tls'] = security != 'none';
    if (security == 'reality') {
      node['reality-opts'] = {
        'public-key': query['pbk'],
        'short-id': query['sid'] ?? '',
      };
    } else if (query.containsKey('pbk') || query.containsKey('sid')) {
      throw const FormatException();
    }
  } else if (type == 'tuic') {
    final split = auth.indexOf(':');
    if (split < 1) throw const FormatException();
    node['uuid'] = auth.substring(0, split);
    node['password'] = auth.substring(split + 1);
    allowed.addAll(['congestion_control', 'udp_relay_mode']);
    if (query['congestion_control'] case final value?) {
      node['congestion-controller'] = value;
    }
    if (query['udp_relay_mode'] case final value?) {
      node['udp-relay-mode'] = value;
    }
  } else {
    node['password'] = auth;
    if (type == 'hysteria2') {
      allowed.addAll(['obfs', 'obfs-password']);
      for (final key in ['obfs', 'obfs-password']) {
        if (query[key] case final value?) node[key] = value;
      }
    }
  }
  if (type != 'socks5') {
    allowed.addAll(['sni', 'alpn', 'fp', 'insecure', 'allowInsecure']);
    _tls(node, query);
  }
  if (type == 'vless' || type == 'trojan') {
    allowed.addAll(['type', 'path', 'host', 'serviceName']);
    _transport(
      node,
      query['type'] ?? 'tcp',
      query['path'],
      query['host'],
      query['serviceName'],
    );
  }
  if (query.keys.any((key) => !allowed.contains(key))) {
    throw const _ShareFailure('unsupported_share_parameter', 'query');
  }
  return node;
}

Map<String, dynamic> _endpoint(Uri uri, String type, int port) {
  if (!uri.hasAuthority ||
      uri.host.isEmpty ||
      uri.host.contains(RegExp(r'[\s\x00]')) ||
      port < 1 ||
      port > 65535 ||
      !const ['', '/'].contains(uri.path)) {
    throw const FormatException();
  }
  return {
    'name': uri.fragment.isEmpty
        ? '$type ${uri.host}:$port'
        : Uri.decodeComponent(uri.fragment),
    'type': type,
    'server': uri.host,
    'port': port,
  };
}

Map<String, String> _query(Uri uri) {
  final result = <String, String>{};
  for (final entry in uri.queryParametersAll.entries) {
    if (entry.value.length != 1) throw const FormatException();
    result[entry.key] = entry.value.single;
  }
  return result;
}

void _tls(Map<String, dynamic> node, Map<String, String> query) {
  for (final entry in {'sni': 'sni', 'fp': 'client-fingerprint'}.entries) {
    if (query[entry.key] case final value?) node[entry.value] = value;
  }
  if (query['alpn'] case final value?) node['alpn'] = value.split(',');
  final insecure = query['insecure'] ?? query['allowInsecure'];
  if (query.containsKey('insecure') &&
      query.containsKey('allowInsecure') &&
      query['insecure'] != query['allowInsecure']) {
    throw const FormatException();
  }
  if (insecure != null) {
    node['skip-cert-verify'] = switch (insecure) {
      '1' || 'true' => true,
      '0' || 'false' => false,
      _ => throw const FormatException(),
    };
  }
}

void _transport(
  Map<String, dynamic> node,
  String network,
  String? path,
  String? host,
  String? service,
) {
  switch (network) {
    case 'tcp':
      if (path != null || host != null || service != null) {
        throw const FormatException();
      }
    case 'ws':
      if (service != null) throw const FormatException();
      node['network'] = 'ws';
      node['ws-opts'] = {
        'path': ?path,
        if (host != null) 'headers': {'Host': host},
      };
    case 'grpc':
      if (path != null || host != null) throw const FormatException();
      node['network'] = 'grpc';
      node['grpc-opts'] = {'grpc-service-name': ?service};
    default:
      throw const _ShareFailure('unsupported_share_transport', 'transport');
  }
}

Map<String, dynamic> _shadowsocks(String source) {
  final hash = source.indexOf('#');
  final fragment = hash < 0 ? '' : source.substring(hash);
  var body = source.substring(5, hash < 0 ? source.length : hash);
  final queryIndex = body.indexOf('?');
  final query = queryIndex < 0 ? '' : body.substring(queryIndex);
  body = queryIndex < 0 ? body : body.substring(0, queryIndex);
  final legacy = !body.contains('@');
  if (legacy) body = _base64Text(body);
  final split = body.lastIndexOf('@');
  if (split < 1) throw const FormatException();
  final uri = Uri.parse('ss://${body.substring(split + 1)}$query$fragment');
  if (!uri.hasPort) throw const FormatException();
  if (_query(uri).isNotEmpty) {
    throw const _ShareFailure('unsupported_shadowsocks_options', 'query');
  }
  final node = _endpoint(uri, 'ss', uri.port);
  var auth = body.substring(0, split);
  if (!legacy) auth = Uri.decodeComponent(auth);
  if (!auth.contains(':')) auth = _base64Text(auth);
  final colon = auth.indexOf(':');
  if (colon < 1) throw const FormatException();
  node['cipher'] = auth.substring(0, colon);
  node['password'] = auth.substring(colon + 1);
  return node;
}

Map<String, dynamic> _vmess(String payload) {
  final value = jsonDecode(_base64Text(payload));
  if (value is! Map<String, dynamic>) throw const FormatException();
  for (final key in [
    'ps',
    'add',
    'id',
    'scy',
    'net',
    'type',
    'host',
    'path',
    'tls',
    'sni',
    'alpn',
    'fp',
  ]) {
    if (value[key] != null && value[key] is! String) {
      throw const FormatException();
    }
  }
  const allowed = {
    'v',
    'ps',
    'add',
    'port',
    'id',
    'aid',
    'scy',
    'net',
    'type',
    'host',
    'path',
    'tls',
    'sni',
    'alpn',
    'fp',
  };
  if (value.keys.any((key) => !allowed.contains(key)) ||
      !const [null, '', 'none'].contains(value['type']) ||
      !const [null, '2', 2].contains(value['v'])) {
    throw const FormatException();
  }
  final port = value['port'] is int
      ? value['port'] as int
      : int.tryParse('${value['port']}');
  if (value['add'] is! String || port == null) throw const FormatException();
  final uri = Uri(
    scheme: 'vmess',
    host: value['add'] as String,
    port: port,
    fragment: value['ps'] as String?,
  );
  final node = _endpoint(uri, 'vmess', port);
  final aid = value['aid'] is int
      ? value['aid']
      : int.tryParse('${value['aid'] ?? 0}');
  if (aid == null) throw const FormatException();
  node.addAll({
    'uuid': value['id'],
    'alterId': aid,
    'cipher': value['scy'] ?? 'auto',
  });
  if (!const [null, '', 'tls'].contains(value['tls'])) {
    throw const FormatException();
  }
  node['tls'] = value['tls'] == 'tls';
  final query = <String, String>{};
  for (final key in ['sni', 'alpn', 'fp']) {
    if (value[key] != null && value[key] != '') {
      if (value[key] is! String) throw const FormatException();
      query[key] = value[key] as String;
    }
  }
  _tls(node, query);
  String? option(String key) {
    if (value[key] == null || value[key] == '') return null;
    if (value[key] is! String) throw const FormatException();
    return value[key] as String;
  }

  final network = option('net') ?? 'tcp';
  _transport(
    node,
    network,
    network == 'grpc' ? null : option('path'),
    option('host'),
    network == 'grpc' ? option('path') : null,
  );
  return node;
}
