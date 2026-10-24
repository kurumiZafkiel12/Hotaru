import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';

enum ImportMode { nodesOnly, fullConfig }

class ImportResult {
  final Map<String, dynamic> config;
  final int nodeCount;
  ImportResult(this.config, this.nodeCount);
}

/// Parses Mihomo YAML/JSON configs and node URIs into Mihomo proxy maps.
///
/// Strictness rule (product decision): a URI parameter or field this parser
/// does not understand is rejected, never silently dropped — a node that
/// imports "successfully" but behaves differently is worse than an error.
class ProfileImporter {
  static const maxBytes = 2 * 1024 * 1024;

  static const _schemes = [
    'socks5',
    'http',
    'https',
    'trojan',
    'ss',
    'vmess',
    'vless',
    'hysteria2',
    'hy2',
  ];

  static ImportResult parse(String input, ImportMode mode) =>
      _parse(input, mode, allowBase64: true);

  static ImportResult _parse(
    String input,
    ImportMode mode, {
    required bool allowBase64,
  }) {
    if (utf8.encode(input).length > maxBytes) {
      throw const FormatException('配置超过 2 MiB 限制');
    }
    final text = input.trim();
    if (text.isEmpty) throw const FormatException('请输入配置或节点链接');
    Map<String, dynamic> config;
    if (RegExp('^(${_schemes.join('|')})://').hasMatch(text)) {
      if (mode == ImportMode.fullConfig) {
        throw const FormatException('节点链接请选择仅导入节点');
      }
      config = {
        'proxies': text
            .split(RegExp(r'\r?\n'))
            .where((s) => s.trim().isNotEmpty)
            .map(_uri)
            .toList(),
      };
    } else {
      Map<String, dynamic>? yamlConfig;
      try {
        final value = jsonDecode(jsonEncode(loadYaml(text)));
        if (value is Map<String, dynamic>) yamlConfig = value;
      } catch (_) {
        yamlConfig = null;
      }
      if (yamlConfig != null) {
        config = yamlConfig;
      } else if (allowBase64) {
        // Many subscriptions are a single Base64 blob wrapping either a URI
        // list or a YAML config. Decode at most once; nested blobs fail.
        final decoded = _tryBase64Text(text);
        if (decoded == null || decoded.trim() == text) {
          throw const FormatException('无法读取 Mihomo YAML/JSON 配置');
        }
        return _parse(decoded, mode, allowBase64: false);
      } else {
        throw const FormatException('无法读取 Mihomo YAML/JSON 配置');
      }
    }
    final proxies = config['proxies'];
    if (proxies is! List || proxies.isEmpty) {
      throw const FormatException('当前需要非空 proxies 列表；远程 provider 暂未支持');
    }
    final names = <String>{};
    for (final node in proxies) {
      if (node is! Map ||
          node['name'] is! String ||
          (node['name'] as String).trim().isEmpty ||
          node['type'] is! String ||
          node['server'] is! String ||
          node['port'] is! int ||
          node['port'] < 1 ||
          node['port'] > 65535) {
        throw const FormatException('节点缺少名称、类型、服务器或有效端口');
      }
      if (!names.add(node['name'])) throw const FormatException('节点名称重复，请先重命名');
    }
    return ImportResult(
      mode == ImportMode.nodesOnly ? {'proxies': proxies} : config,
      proxies.length,
    );
  }

  // ---------- shared helpers ----------

  static String? _tryBase64Text(String text) {
    try {
      return utf8.decode(_base64Bytes(text.replaceAll(RegExp(r'\s'), '')));
    } catch (_) {
      return null;
    }
  }

  static List<int> _base64Bytes(String input) {
    var s = input.replaceAll('-', '+').replaceAll('_', '/');
    if (s.isEmpty || s.length % 4 == 1) throw const FormatException();
    while (s.length % 4 != 0) {
      s += '=';
    }
    return base64.decode(s);
  }

  static String _name(String fragment, String fallback) =>
      fragment.isEmpty ? fallback : Uri.decodeComponent(fragment);

  static void _checkQuery(Uri uri, Set<String> allowed) {
    if (uri.queryParametersAll.keys.any((k) => !allowed.contains(k)) ||
        uri.queryParametersAll.values.any((v) => v.length != 1)) {
      throw const FormatException('链接包含当前不支持的参数');
    }
  }

  static bool? _boolParam(String? value) {
    if (value == null) return null;
    if (value == '1' || value == 'true') return true;
    if (value == '0' || value == 'false') return false;
    throw const FormatException();
  }

  static List<String> _listParam(String? value) =>
      value == null || value.isEmpty
      ? const []
      : value
            .split(',')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();

  static void _hostPort(Uri uri) {
    if (uri.host.isEmpty ||
        !uri.hasPort ||
        uri.port < 1 ||
        uri.port > 65535 ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      throw const FormatException();
    }
  }

  static Map<String, dynamic> _uri(String text) {
    try {
      return _uriInner(text.trim());
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('节点链接无效或含未支持参数');
    }
  }

  static Map<String, dynamic> _uriInner(String text) {
    final uri = Uri.parse(text);
    switch (uri.scheme) {
      case 'socks5':
      case 'http':
      case 'https':
        return _simple(uri);
      case 'trojan':
        return _trojan(uri);
      case 'ss':
        return _shadowsocks(text, uri);
      case 'vmess':
        return _vmess(text, uri);
      case 'vless':
        return _vless(uri);
      case 'hysteria2':
      case 'hy2':
        return _hysteria2(uri);
      default:
        throw const FormatException();
    }
  }

  static Map<String, dynamic> _simple(Uri uri) {
    _hostPort(uri);
    _checkQuery(uri, const <String>{});
    final node = <String, dynamic>{
      'name': _name(uri.fragment, '${uri.scheme}-${uri.host}:${uri.port}'),
      'type': uri.scheme == 'https' ? 'http' : uri.scheme,
      'server': uri.host,
      'port': uri.port,
    };
    if (uri.scheme == 'https') node['tls'] = true;
    if (uri.userInfo.isNotEmpty) {
      final separator = uri.userInfo.indexOf(':');
      if (separator < 0) throw const FormatException();
      node['username'] = Uri.decodeComponent(
        uri.userInfo.substring(0, separator),
      );
      node['password'] = Uri.decodeComponent(
        uri.userInfo.substring(separator + 1),
      );
    }
    return node;
  }

  /// Applies ws/grpc transport options shared by trojan/vless.
  static void _transport(
    Map<String, dynamic> node,
    String? type,
    Map<String, String> q,
  ) {
    final net = type ?? 'tcp';
    if (net == 'tcp') return;
    node['network'] = net;
    if (net == 'ws') {
      final opts = <String, dynamic>{'path': q['path'] ?? '/'};
      if (q['host'] != null) opts['headers'] = {'Host': q['host']};
      node['ws-opts'] = opts;
    } else if (net == 'grpc') {
      node['grpc-opts'] = {'grpc-service-name': q['serviceName'] ?? ''};
    } else {
      throw const FormatException();
    }
  }

  static Map<String, dynamic> _trojan(Uri uri) {
    _hostPort(uri);
    _checkQuery(uri, const {
      'sni',
      'allowInsecure',
      'alpn',
      'type',
      'host',
      'path',
      'serviceName',
    });
    if (uri.userInfo.isEmpty) throw const FormatException();
    final q = uri.queryParameters;
    final node = <String, dynamic>{
      'name': _name(uri.fragment, 'trojan-${uri.host}:${uri.port}'),
      'type': 'trojan',
      'server': uri.host,
      'port': uri.port,
      'password': Uri.decodeComponent(uri.userInfo),
    };
    if (q['sni'] != null) node['sni'] = q['sni'];
    if (_boolParam(q['allowInsecure']) == true) node['skip-cert-verify'] = true;
    final alpn = _listParam(q['alpn']);
    if (alpn.isNotEmpty) node['alpn'] = alpn;
    _transport(node, q['type'], q);
    return node;
  }

  static Map<String, dynamic> _shadowsocks(String text, Uri uri) {
    // Legacy form: ss://base64(method:password@host:port)#name — the whole
    // authority is one Base64 blob, so re-parse after decoding.
    if (!text.split('#').first.contains('@')) {
      final body = text.substring(text.indexOf('://') + 3).split('#').first;
      final decoded = utf8.decode(_base64Bytes(body));
      // Decoded shape is method:password@host:port; split manually because
      // the password may itself contain ':' (method cannot).
      final at = decoded.lastIndexOf('@');
      final colon = decoded.indexOf(':');
      if (at < 0 || colon < 0 || colon > at) throw const FormatException();
      final hostPort = decoded.substring(at + 1);
      final hp = _splitHostPort(hostPort);
      return _ssNode(
        name: _name(uri.fragment, 'ss-${hp.$1}:${hp.$2}'),
        method: decoded.substring(0, colon),
        password: decoded.substring(colon + 1, at),
        host: hp.$1,
        port: hp.$2,
        plugin: null,
      );
    }
    _hostPort(uri);
    _checkQuery(uri, const {'plugin'});
    String method, password;
    if (uri.userInfo.contains(':')) {
      final i = uri.userInfo.indexOf(':');
      method = Uri.decodeComponent(uri.userInfo.substring(0, i));
      password = Uri.decodeComponent(uri.userInfo.substring(i + 1));
    } else {
      final decoded = utf8.decode(
        _base64Bytes(Uri.decodeComponent(uri.userInfo)),
      );
      final i = decoded.indexOf(':');
      if (i < 0) throw const FormatException();
      method = decoded.substring(0, i);
      password = decoded.substring(i + 1);
    }
    return _ssNode(
      name: _name(uri.fragment, 'ss-${uri.host}:${uri.port}'),
      method: method,
      password: password,
      host: uri.host,
      port: uri.port,
      plugin: uri.queryParameters['plugin'],
    );
  }

  static (String, int) _splitHostPort(String hostPort) {
    if (hostPort.startsWith('[')) {
      final end = hostPort.indexOf(']');
      if (end < 0 || hostPort[end + 1] != ':') throw const FormatException();
      final port = int.tryParse(hostPort.substring(end + 2));
      if (port == null || port < 1 || port > 65535) {
        throw const FormatException();
      }
      return (hostPort.substring(1, end), port);
    }
    final i = hostPort.lastIndexOf(':');
    if (i <= 0) throw const FormatException();
    final port = int.tryParse(hostPort.substring(i + 1));
    if (port == null || port < 1 || port > 65535) {
      throw const FormatException();
    }
    return (hostPort.substring(0, i), port);
  }

  static Map<String, dynamic> _ssNode({
    required String name,
    required String method,
    required String password,
    required String host,
    required int port,
    required String? plugin,
  }) {
    if (method.isEmpty || password.isEmpty || host.isEmpty) {
      throw const FormatException();
    }
    final node = <String, dynamic>{
      'name': name,
      'type': 'ss',
      'server': host,
      'port': port,
      'cipher': method,
      'password': password,
      'udp': true,
    };
    if (plugin != null && plugin.isNotEmpty) {
      final parts = plugin.split(';');
      final kind = parts.first;
      final opts = <String, String>{};
      for (final part in parts.skip(1)) {
        final eq = part.indexOf('=');
        if (eq < 0) throw const FormatException();
        opts[part.substring(0, eq)] = part.substring(eq + 1);
      }
      if (kind == 'obfs-local' || kind == 'obfs') {
        if (opts.keys.any((k) => !{'obfs', 'obfs-host'}.contains(k))) {
          throw const FormatException();
        }
        node['plugin'] = 'obfs';
        node['plugin-opts'] = {
          'mode': opts['obfs'] ?? 'http',
          if (opts['obfs-host'] != null) 'host': opts['obfs-host'],
        };
      } else if (kind == 'v2ray-plugin') {
        if (opts.keys.any(
          (k) => !{'mode', 'host', 'path', 'tls', 'mux'}.contains(k),
        )) {
          throw const FormatException();
        }
        node['plugin'] = 'v2ray-plugin';
        node['plugin-opts'] = {
          'mode': opts['mode'] ?? 'websocket',
          if (opts['host'] != null) 'host': opts['host'],
          if (opts['path'] != null) 'path': opts['path'],
          if (opts['tls'] != null) 'tls': true,
          if (opts['mux'] != null) 'mux': opts['mux'] == 'true',
        };
      } else {
        throw const FormatException();
      }
    }
    return node;
  }

  static Map<String, dynamic> _vmess(String text, Uri uri) {
    final body = text.substring(text.indexOf('://') + 3).split('#').first;
    final decoded = jsonDecode(utf8.decode(_base64Bytes(body)));
    if (decoded is! Map<String, dynamic>) throw const FormatException();
    const known = {
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
    if (decoded.keys.any((k) => !known.contains(k))) {
      throw const FormatException();
    }
    String str(String key) => decoded[key]?.toString() ?? '';
    final port = int.tryParse(str('port'));
    final aid = int.tryParse(str('aid').isEmpty ? '0' : str('aid'));
    if (str('add').isEmpty ||
        str('id').isEmpty ||
        port == null ||
        port < 1 ||
        port > 65535 ||
        aid == null ||
        aid < 0) {
      throw const FormatException();
    }
    final cipher = str('scy').isEmpty ? 'auto' : str('scy');
    if (!{
      'auto',
      'aes-128-gcm',
      'chacha20-poly1305',
      'none',
      'zero',
    }.contains(cipher)) {
      throw const FormatException();
    }
    final net = str('net').isEmpty ? 'tcp' : str('net');
    if (!{'tcp', 'ws', 'h2', 'http', 'grpc'}.contains(net)) {
      throw const FormatException();
    }
    final tlsValue = str('tls');
    if (tlsValue != '' && tlsValue != 'tls') throw const FormatException();
    final node = <String, dynamic>{
      'name': str('ps').isEmpty ? 'vmess-${str('add')}:$port' : str('ps'),
      'type': 'vmess',
      'server': str('add'),
      'port': port,
      'uuid': str('id'),
      'alterId': aid,
      'cipher': cipher,
      'udp': true,
    };
    if (net != 'tcp') node['network'] = net;
    if (tlsValue == 'tls') node['tls'] = true;
    if (str('sni').isNotEmpty) node['servername'] = str('sni');
    if (str('fp').isNotEmpty) node['client-fingerprint'] = str('fp');
    final alpn = _listParam(str('alpn'));
    if (alpn.isNotEmpty) node['alpn'] = alpn;
    final host = str('host'), path = str('path'), headerType = str('type');
    switch (net) {
      case 'ws':
        node['ws-opts'] = {
          'path': path.isEmpty ? '/' : path,
          if (host.isNotEmpty) 'headers': {'Host': host},
        };
      case 'h2':
        node['h2-opts'] = {
          'path': path.isEmpty ? '/' : path,
          if (host.isNotEmpty) 'host': [host],
        };
      case 'http':
        node['http-opts'] = {
          'path': [path.isEmpty ? '/' : path],
          if (host.isNotEmpty)
            'headers': {
              'Host': [host],
            },
        };
      case 'grpc':
        node['grpc-opts'] = {'grpc-service-name': path};
      case 'tcp':
        if (headerType == 'http') {
          node['http-opts'] = {
            'path': [path.isEmpty ? '/' : path],
            if (host.isNotEmpty)
              'headers': {
                'Host': [host],
              },
          };
        } else if (headerType.isNotEmpty && headerType != 'none') {
          throw const FormatException();
        }
    }
    return node;
  }

  static Map<String, dynamic> _vless(Uri uri) {
    _hostPort(uri);
    _checkQuery(uri, const {
      'encryption',
      'security',
      'sni',
      'fp',
      'type',
      'host',
      'path',
      'serviceName',
      'pbk',
      'sid',
      'flow',
      'allowInsecure',
      'alpn',
    });
    if (uri.userInfo.isEmpty) throw const FormatException();
    final q = uri.queryParameters;
    if (q['encryption'] != null && q['encryption'] != 'none') {
      throw const FormatException();
    }
    final flow = q['flow'];
    if (flow != null && flow.isNotEmpty && flow != 'xtls-rprx-vision') {
      throw const FormatException();
    }
    final security = q['security'] ?? 'none';
    if (!{'none', 'tls', 'reality'}.contains(security)) {
      throw const FormatException();
    }
    final node = <String, dynamic>{
      'name': _name(uri.fragment, 'vless-${uri.host}:${uri.port}'),
      'type': 'vless',
      'server': uri.host,
      'port': uri.port,
      'uuid': Uri.decodeComponent(uri.userInfo),
      'udp': true,
    };
    if (security != 'none') node['tls'] = true;
    if (security == 'reality') {
      final pbk = q['pbk'];
      if (pbk == null || pbk.isEmpty) throw const FormatException();
      node['reality-opts'] = {
        'public-key': pbk,
        if (q['sid'] != null) 'short-id': q['sid'],
      };
    }
    if (q['sni'] != null) node['servername'] = q['sni'];
    if (q['fp'] != null) node['client-fingerprint'] = q['fp'];
    if (flow != null && flow.isNotEmpty) node['flow'] = flow;
    if (_boolParam(q['allowInsecure']) == true) node['skip-cert-verify'] = true;
    final alpn = _listParam(q['alpn']);
    if (alpn.isNotEmpty) node['alpn'] = alpn;
    _transport(node, q['type'], q);
    return node;
  }

  static Map<String, dynamic> _hysteria2(Uri uri) {
    _hostPort(uri);
    _checkQuery(uri, const {
      'insecure',
      'sni',
      'obfs',
      'obfs-password',
      'alpn',
      'up',
      'down',
    });
    if (uri.userInfo.isEmpty) throw const FormatException();
    final q = uri.queryParameters;
    final node = <String, dynamic>{
      'name': _name(uri.fragment, 'hysteria2-${uri.host}:${uri.port}'),
      'type': 'hysteria2',
      'server': uri.host,
      'port': uri.port,
      'password': Uri.decodeComponent(uri.userInfo),
    };
    if (q['sni'] != null) node['sni'] = q['sni'];
    if (_boolParam(q['insecure']) == true) node['skip-cert-verify'] = true;
    final obfs = q['obfs'];
    if (obfs != null) {
      if (obfs != 'salamander') throw const FormatException();
      final obfsPassword = q['obfs-password'];
      if (obfsPassword == null || obfsPassword.isEmpty) {
        throw const FormatException();
      }
      node['obfs'] = obfs;
      node['obfs-password'] = obfsPassword;
    }
    final alpn = _listParam(q['alpn']);
    if (alpn.isNotEmpty) node['alpn'] = alpn;
    if (q['up'] != null) node['up'] = q['up'];
    if (q['down'] != null) node['down'] = q['down'];
    return node;
  }

  static Future<String> fetch(Uri uri) async {
    if (uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
      throw const FormatException('订阅必须是 HTTPS 地址，且不能包含 URL 用户名密码');
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      return await (() async {
        final request = await client.getUrl(uri);
        request.followRedirects = false;
        final response = await request.close();
        if (response.statusCode != 200) {
          throw const FormatException('订阅下载失败；暂不自动跟随重定向');
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > maxBytes) {
            throw const FormatException('订阅超过 2 MiB 限制');
          }
          bytes.addAll(chunk);
        }
        return utf8.decode(bytes);
      })().timeout(const Duration(seconds: 20));
    } finally {
      client.close(force: true);
    }
  }
}
