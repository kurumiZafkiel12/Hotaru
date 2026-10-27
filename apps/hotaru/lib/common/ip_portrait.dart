import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

/// One geolocation source's answer for the same address, so the page
/// can lay the sources side by side instead of trusting one of them.
class GeoSourceResult {
  const GeoSourceResult({required this.source, this.countryCode, this.city});

  final String source;
  final String? countryCode;
  final String? city;

  bool get answered => countryCode != null && countryCode!.isNotEmpty;
}

Map<String, dynamic>? _asMap(Object? data) {
  Object? decoded;
  try {
    decoded = data is String ? jsonDecode(data) : data;
  } on FormatException {
    return null;
  }
  return decoded is Map<String, dynamic> ? decoded : null;
}

String? _text(Object? value) {
  final text = '$value'.trim();
  return value == null || text.isEmpty || text == 'null' ? null : text;
}

GeoSourceResult parseIpApiGeo(Object? data) {
  final json = _asMap(data);
  if (json == null || json['status'] != 'success') {
    return const GeoSourceResult(source: 'IP-API');
  }
  return GeoSourceResult(
    source: 'IP-API',
    countryCode: _text(json['countryCode']),
    city: _text(json['city']),
  );
}

GeoSourceResult parseIpWhoGeo(Object? data) {
  final json = _asMap(data);
  if (json == null || json['success'] == false) {
    return const GeoSourceResult(source: 'ipwho.is');
  }
  return GeoSourceResult(
    source: 'ipwho.is',
    countryCode: _text(json['country_code']),
    city: _text(json['city']),
  );
}

GeoSourceResult parseDbIpGeo(Object? data) {
  final json = _asMap(data);
  if (json == null) {
    return const GeoSourceResult(source: 'DB-IP');
  }
  return GeoSourceResult(
    source: 'DB-IP',
    countryCode: _text(json['countryCode']),
    city: _text(json['city']),
  );
}

GeoSourceResult parseIpInfoGeo(Object? data) {
  final json = _asMap(data);
  if (json == null || json['bogon'] == true) {
    return const GeoSourceResult(source: 'ipinfo.io');
  }
  return GeoSourceResult(
    source: 'ipinfo.io',
    countryCode: _text(json['country']),
    city: _text(json['city']),
  );
}

GeoSourceResult parseIpSbGeo(Object? data) {
  final json = _asMap(data);
  if (json == null) {
    return const GeoSourceResult(source: 'IP.SB');
  }
  return GeoSourceResult(
    source: 'IP.SB',
    countryCode: _text(json['country_code']),
    city: _text(json['city']),
  );
}

/// Asks five independent geolocation sources about [ip] in parallel;
/// a source that fails simply answers with nothing.
Future<List<GeoSourceResult>> lookupGeoSources(
  Dio dio,
  String ip, {
  CancelToken? cancelToken,
}) async {
  final options = Options(
    responseType: ResponseType.plain,
    receiveTimeout: const Duration(seconds: 6),
    sendTimeout: const Duration(seconds: 6),
  );
  Future<GeoSourceResult> ask(
    String url,
    GeoSourceResult Function(Object?) parse,
    GeoSourceResult empty,
  ) async {
    try {
      final response = await dio.get<String>(
        url,
        options: options,
        cancelToken: cancelToken,
      );
      return parse(response.data);
    } catch (_) {
      return empty;
    }
  }

  return Future.wait([
    ask(
      'http://ip-api.com/json/$ip?fields=status,countryCode,city',
      parseIpApiGeo,
      const GeoSourceResult(source: 'IP-API'),
    ),
    ask(
      'https://ipwho.is/$ip',
      parseIpWhoGeo,
      const GeoSourceResult(source: 'ipwho.is'),
    ),
    ask(
      'https://api.db-ip.com/v2/free/$ip',
      parseDbIpGeo,
      const GeoSourceResult(source: 'DB-IP'),
    ),
    ask(
      'https://ipinfo.io/$ip/json',
      parseIpInfoGeo,
      const GeoSourceResult(source: 'ipinfo.io'),
    ),
    ask(
      'https://api.ip.sb/geoip/$ip',
      parseIpSbGeo,
      const GeoSourceResult(source: 'IP.SB'),
    ),
  ]);
}

/// The named-source risk reading for the portrait's gauge: proxycheck
/// scores addresses 0–100, and also publishes the range and hostname.
class ProxyCheckDetails {
  const ProxyCheckDetails({this.risk, this.range, this.hostname});

  final int? risk;
  final String? range;
  final String? hostname;
}

ProxyCheckDetails parseProxyCheckDetails(Object? data, String ip) {
  final json = _asMap(data);
  final result = json == null ? null : _asMap(json[ip]);
  if (result == null) {
    return const ProxyCheckDetails();
  }
  final detections = _asMap(result['detections']);
  final network = _asMap(result['network']);
  final risk = detections?['risk'];
  return ProxyCheckDetails(
    risk: risk is num ? risk.round() : null,
    range: _text(network?['range']),
    hostname: _text(network?['hostname']),
  );
}

Future<ProxyCheckDetails?> lookupProxyCheckDetails(
  Dio dio,
  String ip, {
  CancelToken? cancelToken,
}) async {
  try {
    final response = await dio.get<String>(
      'https://proxycheck.io/v3/$ip',
      options: Options(
        responseType: ResponseType.plain,
        receiveTimeout: const Duration(seconds: 6),
        sendTimeout: const Duration(seconds: 6),
      ),
      cancelToken: cancelToken,
    );
    return parseProxyCheckDetails(response.data, ip);
  } catch (_) {
    return null;
  }
}
