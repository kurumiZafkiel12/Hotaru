import 'dart:convert';
import 'dart:isolate';

import 'package:collection/collection.dart';

import 'clash_importer.dart';
import 'encoding.dart';
import 'node_definition.dart';
import 'node_validation.dart';
import 'profile.dart';
import 'share_links.dart';

final class CoreShareLinkEncoder {
  static Future<List<String>> encode(List<Map<String, dynamic>> definitions) =>
      Isolate.run(() async {
        final parsed = await ClashProfileImporter().importNodes(definitions);
        final result = List.filled(parsed.length, '');
        final candidates = <String>[];
        final indexes = <int>[];
        var bytes = 0;
        for (var index = 0; index < parsed.length; index++) {
          final item = parsed[index];
          final node = item.node;
          if (item.issues.isNotEmpty ||
              node == null ||
              node.tag.isEmpty ||
              validateCoreNodeFields(node, path: 'node').isNotEmpty) {
            continue;
          }
          final String? link;
          try {
            link = _encode(node);
          } on FormatException {
            continue;
          }
          if (link == null || utf8.encode(link).length > 65536) continue;
          bytes += utf8.encode(link).length;
          if (bytes > CoreConfigEncoding.maxBytes) {
            throw const CoreConfigSizeException();
          }
          candidates.add(link);
          indexes.add(index);
        }
        final decoded = await CoreShareLinks.decodeMany(candidates);
        final roundTrips = await ClashProfileImporter().importNodes([
          for (final item in decoded)
            item.issues.isEmpty && item.nodes.length == 1
                ? item.nodes.single
                : <String, dynamic>{},
        ]);
        for (var index = 0; index < roundTrips.length; index++) {
          final checked = roundTrips[index];
          if (checked.issues.isEmpty &&
              checked.node != null &&
              const DeepCollectionEquality().equals(
                _canonical(checked.node!),
                _canonical(parsed[indexes[index]].node!),
              )) {
            result[indexes[index]] = candidates[index];
          }
        }
        return result;
      });
}

Map<String, dynamic> _canonical(CoreNodeSpec node) {
  final definition = CoreNodeDefinition.fromNode(node);
  if (node.protocol == CoreNodeProtocol.vmess) {
    definition['alterId'] ??= 0;
    definition['cipher'] ??= 'auto';
  }
  return definition;
}

String? _encode(CoreNodeSpec node) {
  if (node.protocol == CoreNodeProtocol.direct ||
      node.detour != null ||
      node.tcpOnly) {
    return null;
  }
  final tls = node.tls;
  final transport = node.transport;
  final query = <String, String>{
    'sni': ?tls?.serverName,
    'fp': ?tls?.fingerprint,
    if (tls?.insecure == true) 'insecure': '1',
    if (tls != null && tls.alpn.isNotEmpty) 'alpn': tls.alpn.join(','),
    if (transport != null) ...{
      'type': transport.kind.name,
      'path': ?transport.path,
      'host': ?transport.headers['Host'],
      'serviceName': ?transport.serviceName,
    },
  };
  String scheme;
  String userInfo;
  switch (node.protocol) {
    case CoreNodeProtocol.direct:
      return null;
    case CoreNodeProtocol.http:
      scheme = tls == null ? 'http' : 'https';
      userInfo = _userPassword(node.username, node.password);
    case CoreNodeProtocol.socks:
      scheme = 'socks5';
      userInfo = _userPassword(node.username, node.password);
    case CoreNodeProtocol.shadowsocks:
      scheme = 'ss';
      userInfo = base64Url.encode(
        utf8.encode('${node.cipher}:${node.password}'),
      );
    case CoreNodeProtocol.vmess:
      final value = {
        'v': '2',
        'ps': node.tag,
        'add': node.server,
        'port': node.port,
        'id': node.uuid,
        'aid': node.alterId ?? 0,
        'scy': node.cipher ?? 'auto',
        'net': transport?.kind.name ?? 'tcp',
        'path': ?(transport?.kind == CoreTransportKind.grpc
            ? transport?.serviceName
            : transport?.path),
        'host': ?transport?.headers['Host'],
        'tls': tls == null ? '' : 'tls',
        'sni': ?tls?.serverName,
        'fp': ?tls?.fingerprint,
        if (tls != null && tls.alpn.isNotEmpty) 'alpn': tls.alpn.join(','),
      };
      return 'vmess://${base64Url.encode(utf8.encode(jsonEncode(value)))}';
    case CoreNodeProtocol.vless:
      scheme = 'vless';
      userInfo = Uri.encodeComponent(node.uuid!);
      query.addAll({
        'security': tls == null
            ? 'none'
            : tls.realityPublicKey == null
            ? 'tls'
            : 'reality',
        'flow': ?node.flow,
        'pbk': ?tls?.realityPublicKey,
        'sid': ?tls?.realityShortId,
      });
    case CoreNodeProtocol.trojan:
      scheme = 'trojan';
      userInfo = Uri.encodeComponent(node.password!);
    case CoreNodeProtocol.hysteria2:
      scheme = 'hysteria2';
      userInfo = Uri.encodeComponent(node.password!);
      query.addAll({
        if (node.obfsPassword != null) 'obfs': 'salamander',
        'obfs-password': ?node.obfsPassword,
      });
    case CoreNodeProtocol.tuic:
      scheme = 'tuic';
      userInfo = _userPassword(node.uuid, node.password);
      query.addAll({
        'congestion_control': ?node.congestionControl,
        'udp_relay_mode': ?node.udpRelayMode,
      });
  }
  return Uri(
    scheme: scheme,
    userInfo: userInfo,
    host: node.server!,
    port: node.port!,
    queryParameters: query.isEmpty ? null : query,
    fragment: Uri.encodeComponent(node.tag),
  ).toString();
}

String _userPassword(String? user, String? password) =>
    user == null && password == null
    ? ''
    : '${Uri.encodeComponent(user ?? '')}:${Uri.encodeComponent(password ?? '')}';
