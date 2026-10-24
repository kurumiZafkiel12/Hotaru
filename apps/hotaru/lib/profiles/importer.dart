import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';

enum ImportMode { nodesOnly, fullConfig }

class ImportResult {
  final Map<String, dynamic> config;
  final int nodeCount;
  ImportResult(this.config, this.nodeCount);
}

class ProfileImporter {
  static const maxBytes = 2 * 1024 * 1024;

  static ImportResult parse(String input, ImportMode mode) {
    if (utf8.encode(input).length > maxBytes) {
      throw const FormatException('配置超过 2 MiB 限制');
    }
    final text = input.trim();
    if (text.isEmpty) throw const FormatException('请输入配置或节点链接');
    Map<String, dynamic> config;
    if (RegExp(r'^(socks5|https?|trojan)://').hasMatch(text)) {
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
      try {
        final value = jsonDecode(jsonEncode(loadYaml(text)));
        if (value is! Map<String, dynamic>) throw const FormatException();
        config = value;
      } catch (_) {
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

  static Map<String, dynamic> _uri(String text) {
    try {
      final uri = Uri.parse(text.trim());
      if (!['socks5', 'http', 'https', 'trojan'].contains(uri.scheme) ||
          uri.host.isEmpty ||
          !uri.hasPort ||
          uri.port < 1 ||
          uri.port > 65535 ||
          uri.path.isNotEmpty && uri.path != '/') {
        throw const FormatException();
      }
      final allowed = uri.scheme == 'trojan' ? {'sni'} : <String>{};
      if (uri.queryParametersAll.keys.any((k) => !allowed.contains(k)) ||
          uri.queryParametersAll.values.any((v) => v.length != 1)) {
        throw const FormatException('链接包含当前不支持的参数');
      }
      final node = <String, dynamic>{
        'name': uri.fragment.isEmpty
            ? '${uri.scheme}-${uri.host}:${uri.port}'
            : Uri.decodeComponent(uri.fragment),
        'type': uri.scheme == 'https' ? 'http' : uri.scheme,
        'server': uri.host,
        'port': uri.port,
      };
      if (uri.scheme == 'https') node['tls'] = true;
      if (uri.scheme == 'trojan') {
        if (uri.userInfo.isEmpty) throw const FormatException();
        node['password'] = Uri.decodeComponent(uri.userInfo);
        if (uri.queryParameters.containsKey('sni')) {
          node['sni'] = uri.queryParameters['sni'];
        }
      } else if (uri.userInfo.isNotEmpty) {
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
    } catch (_) {
      throw const FormatException(
        '节点链接无效或含未支持参数；当前支持 SOCKS5、HTTP(S)、基础 Trojan',
      );
    }
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
