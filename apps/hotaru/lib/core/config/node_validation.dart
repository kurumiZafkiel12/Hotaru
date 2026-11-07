import 'profile.dart';

List<CoreConfigIssue> validateCoreNodeFields(
  CoreNodeSpec node, {
  required String path,
}) {
  final issues = <CoreConfigIssue>[];
  final options = <String, Object?>{
    'username': node.username,
    'password': node.password,
    'uuid': node.uuid,
    'cipher': node.cipher,
    'alterId': node.alterId,
    'flow': node.flow,
    'tls': node.tls,
    'transport': node.transport,
    'congestionControl': node.congestionControl,
    'udpRelayMode': node.udpRelayMode,
    'obfsPassword': node.obfsPassword,
    'upMbps': node.upMbps,
    'downMbps': node.downMbps,
  };
  final allowed = switch (node.protocol) {
    CoreNodeProtocol.direct => <String>{},
    CoreNodeProtocol.http => {'username', 'password', 'tls'},
    CoreNodeProtocol.socks => {'username', 'password'},
    CoreNodeProtocol.shadowsocks => {'password', 'cipher'},
    CoreNodeProtocol.vmess => {'uuid', 'cipher', 'alterId', 'tls', 'transport'},
    CoreNodeProtocol.vless => {'uuid', 'flow', 'tls', 'transport'},
    CoreNodeProtocol.trojan => {'password', 'tls', 'transport'},
    CoreNodeProtocol.hysteria2 => {
      'password',
      'tls',
      'obfsPassword',
      'upMbps',
      'downMbps',
    },
    CoreNodeProtocol.tuic => {
      'uuid',
      'password',
      'tls',
      'congestionControl',
      'udpRelayMode',
    },
  };
  for (final option in options.entries) {
    if (option.value != null && !allowed.contains(option.key)) {
      issues.add(
        CoreConfigIssue('unsupported_protocol_option', '$path.${option.key}'),
      );
    }
  }
  if (node.tls?.realityPublicKey != null &&
      node.protocol != CoreNodeProtocol.vless) {
    issues.add(CoreConfigIssue('unsupported_reality', path));
  }
  if (node.transport case final transport?) {
    if (transport.kind == CoreTransportKind.grpc &&
            (transport.path != null || transport.headers.isNotEmpty) ||
        transport.kind == CoreTransportKind.ws &&
            transport.serviceName != null) {
      issues.add(CoreConfigIssue('incompatible_transport_options', path));
    }
  }
  if (node.protocol == CoreNodeProtocol.direct) {
    if (node.server != null ||
        node.port != null ||
        node.username != null ||
        node.password != null ||
        node.tls != null ||
        node.transport != null ||
        node.detour != null) {
      issues.add(CoreConfigIssue('direct_has_proxy_fields', path));
    }
  } else if (node.server == null ||
      node.server!.trim().isEmpty ||
      node.port == null ||
      node.port! < 1 ||
      node.port! > 65535) {
    issues.add(CoreConfigIssue('invalid_server', path));
  }
  if (const [
        CoreNodeProtocol.http,
        CoreNodeProtocol.socks,
      ].contains(node.protocol) &&
      (node.username == null) != (node.password == null)) {
    issues.add(CoreConfigIssue('incomplete_credentials', path));
  }
  if (const [
        CoreNodeProtocol.vless,
        CoreNodeProtocol.vmess,
        CoreNodeProtocol.tuic,
      ].contains(node.protocol) &&
      (node.uuid == null ||
          !RegExp(
            r'^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$',
          ).hasMatch(node.uuid!))) {
    issues.add(CoreConfigIssue('invalid_uuid', path));
  }
  if (const [
        CoreNodeProtocol.shadowsocks,
        CoreNodeProtocol.trojan,
        CoreNodeProtocol.hysteria2,
        CoreNodeProtocol.tuic,
      ].contains(node.protocol) &&
      (node.password == null || node.password!.isEmpty)) {
    issues.add(CoreConfigIssue('missing_password', path));
  }
  if (node.protocol == CoreNodeProtocol.shadowsocks &&
      (node.cipher == null || node.cipher!.isEmpty)) {
    issues.add(CoreConfigIssue('missing_cipher', path));
  }
  if (const [
        CoreNodeProtocol.hysteria2,
        CoreNodeProtocol.tuic,
      ].contains(node.protocol) &&
      node.tls == null) {
    issues.add(CoreConfigIssue('tls_required', path));
  }
  if (node.transport != null &&
      !const [
        CoreNodeProtocol.vmess,
        CoreNodeProtocol.vless,
        CoreNodeProtocol.trojan,
      ].contains(node.protocol)) {
    issues.add(CoreConfigIssue('unsupported_transport', path));
  }
  if (node.tls != null &&
      const [
        CoreNodeProtocol.socks,
        CoreNodeProtocol.shadowsocks,
      ].contains(node.protocol)) {
    issues.add(CoreConfigIssue('unsupported_tls', path));
  }
  return issues;
}
