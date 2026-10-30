import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hotaru/models/models.dart';

import 'network_diagnostics.dart';

enum IpPortraitSource {
  ipQuery('IPQuery'),
  ipApiIs('ipapi.is'),
  geoJs('GeoJS');

  const IpPortraitSource(this.label);
  final String label;

  String url(String ip) => switch (this) {
    ipQuery => 'https://api.ipquery.io/$ip?format=json',
    ipApiIs => 'https://api.ipapi.is/?q=$ip',
    geoJs => 'https://get.geojs.io/v1/ip/geo/$ip.json',
  };
}

class IpPortraitObservation {
  const IpPortraitObservation({
    required this.source,
    required this.ip,
    required this.checkedAt,
    this.country = '',
    this.city = '',
    this.organization = '',
    this.asn = '',
    this.access = '',
    this.flags = const {},
    this.metrics = const {},
    this.error,
  });

  final IpPortraitSource source;
  final String ip;
  final DateTime checkedAt;
  final String country;
  final String city;
  final String organization;
  final String asn;
  final String access;
  final Map<String, bool> flags;
  final Map<String, String> metrics;
  final String? error;

  bool get reportsRisk =>
      const ['proxy', 'vpn', 'tor', 'abuser'].any((key) => flags[key] == true);

  factory IpPortraitObservation.parse(
    IpPortraitSource source,
    String ip,
    String body,
    DateTime checkedAt,
  ) {
    final decoded = jsonDecode(body);
    if (decoded is! Map) throw const FormatException('invalid IP profile');
    final json = Map<String, dynamic>.from(decoded);
    final returned = InternetAddress.tryParse(_text(json['ip']));
    final expected = InternetAddress.tryParse(ip);
    if (returned == null ||
        expected == null ||
        returned.address != expected.address ||
        !isPublicProbeAddress(returned)) {
      throw const FormatException('IP profile address mismatch');
    }
    final location = _map(json['location']);
    final isp = _map(json['isp']);
    final asn = _map(json['asn']);
    final company = _map(json['company']);
    final risk = source == IpPortraitSource.ipQuery ? _map(json['risk']) : json;
    final flags = <String, bool>{
      if (source != IpPortraitSource.geoJs)
        for (final key in [
          'proxy',
          'vpn',
          'tor',
          'abuser',
          'datacenter',
          'mobile',
        ])
          if (risk['is_$key'] case final bool flag) key: flag,
    };
    final explicitType = _text(company['type']).toLowerCase();
    final access = flags['mobile'] == true
        ? 'mobile'
        : flags['datacenter'] == true
        ? 'hosting'
        : const {
            'isp',
            'hosting',
            'business',
            'education',
            'government',
          }.contains(explicitType)
        ? explicitType
        : '';
    final country = _text(
      source == IpPortraitSource.geoJs
          ? json['country_code']
          : location['country_code'],
    ).toUpperCase();
    return IpPortraitObservation(
      source: source,
      ip: returned.address,
      checkedAt: checkedAt,
      country: RegExp(r'^[A-Z]{2}$').hasMatch(country) ? country : '',
      city: _text(
        source == IpPortraitSource.geoJs ? json['city'] : location['city'],
      ),
      organization: _text(switch (source) {
        IpPortraitSource.ipQuery => isp['org'] ?? isp['isp'],
        IpPortraitSource.ipApiIs => asn['org'] ?? company['name'],
        IpPortraitSource.geoJs =>
          json['organization_name'] ?? json['organization'],
      }),
      asn: _text(
        source == IpPortraitSource.geoJs
            ? json['asn']
            : source == IpPortraitSource.ipQuery
            ? isp['asn']
            : asn['asn'],
      ),
      access: access,
      flags: Map.unmodifiable(flags),
      metrics: Map.unmodifiable({
        if (source == IpPortraitSource.ipQuery)
          if (risk['risk_score'] case final num value)
            if (value.isFinite && value >= 0 && value <= 100)
              'risk_score': '$value',
        if (source == IpPortraitSource.ipApiIs &&
            company['abuser_score'] != null)
          'company.abuser_score': _text(company['abuser_score']),
      }),
    );
  }
}

Map<String, dynamic> _map(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : const {};
String _text(Object? value) {
  if (value is! String && value is! num) return '';
  final text = '$value'.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '');
  return text.length > 200 ? text.substring(0, 200) : text;
}

class IpExitObservation {
  const IpExitObservation({
    required this.family,
    required this.checkedAt,
    this.ip,
    this.route,
    this.error,
  });
  final int family;
  final DateTime checkedAt;
  final String? ip;
  final OutboundIpResult? route;
  final String? error;
}

class IpPortraitRoute {
  const IpPortraitRoute({required this.label, required this.url, this.reply});
  final String label;
  final String url;
  final ProbeResult? reply;
}

class IpPortraitReport {
  const IpPortraitReport({
    required this.checkedAt,
    required this.exits,
    required this.sources,
    this.routes = const [],
  });
  final DateTime checkedAt;
  final List<IpExitObservation> exits;
  final List<IpPortraitObservation> sources;
  final List<IpPortraitRoute> routes;
  Iterable<String> get addresses => exits.map((exit) => exit.ip).nonNulls;
  bool get hasRisk => sources.any((source) => source.reportsRisk);
  bool get hasDisagreement {
    for (final ip in addresses) {
      final answers = sources.where(
        (source) => source.ip == ip && source.error == null,
      );
      if (answers
              .map((answer) => answer.country)
              .where((value) => value.isNotEmpty)
              .toSet()
              .length >
          1) {
        return true;
      }
      if (answers
              .map((answer) => answer.access)
              .where((value) => value.isNotEmpty)
              .toSet()
              .length >
          1) {
        return true;
      }
      for (final key in [
        'proxy',
        'vpn',
        'tor',
        'abuser',
        'datacenter',
        'mobile',
      ]) {
        if (answers.map((answer) => answer.flags[key]).nonNulls.toSet().length >
            1) {
          return true;
        }
      }
    }
    return false;
  }
}

class IpPortraitRunner {
  IpPortraitRunner({
    required this.request,
    required this.coreEpoch,
    required this.routeVersion,
    this.probeRoute,
  });
  final Future<OutboundIpResult?> Function(OutboundIpParams) request;
  final int coreEpoch;
  final int routeVersion;
  final Future<ProbeResult?> Function(ProbeParams)? probeRoute;
  bool _cancelled = false;
  void cancel() => _cancelled = true;

  Future<OutboundIpResult> _query(String url) async {
    if (_cancelled) throw const FormatException('cancelled');
    final reply = await request(OutboundIpParams(urls: [url], timeout: 8000));
    if (_cancelled ||
        reply == null ||
        reply.error != null ||
        reply.url != url ||
        reply.coreEpoch != coreEpoch ||
        reply.routeVersion != routeVersion) {
      throw const FormatException('IP profile route unavailable or changed');
    }
    return reply;
  }

  Future<IpPortraitReport> run() async {
    final exits = await Future.wait([
      for (final family in [4, 6])
        () async {
          try {
            final reply = await _query(
              family == 4
                  ? 'https://api.ipify.org?format=json'
                  : 'https://api6.ipify.org?format=json',
            );
            final json = jsonDecode(reply.body);
            final ip = json is Map
                ? InternetAddress.tryParse(_text(json['ip']))
                : null;
            if (ip == null ||
                !isPublicProbeAddress(ip) ||
                (ip.type == InternetAddressType.IPv4 ? 4 : 6) != family) {
              throw const FormatException('invalid IP family');
            }
            return IpExitObservation(
              family: family,
              ip: ip.address,
              route: reply,
              checkedAt: DateTime.now(),
            );
          } catch (_) {
            return IpExitObservation(
              family: family,
              error: 'unavailable',
              checkedAt: DateTime.now(),
            );
          }
        }(),
    ]);
    final observations = <IpPortraitObservation>[];
    for (final exit in exits) {
      final ip = exit.ip;
      if (ip == null || _cancelled) continue;
      final answers = await Future.wait([
        for (final source in IpPortraitSource.values)
          () async {
            try {
              final reply = await _query(source.url(ip));
              return IpPortraitObservation.parse(
                source,
                ip,
                reply.body,
                DateTime.now(),
              );
            } catch (_) {
              return IpPortraitObservation(
                source: source,
                ip: ip,
                checkedAt: DateTime.now(),
                error: 'unavailable',
              );
            }
          }(),
      ]);
      if (!_cancelled) observations.addAll(answers);
    }
    final routes = <IpPortraitRoute>[];
    final routeProbe = probeRoute;
    if (routeProbe != null && !_cancelled) {
      routes.addAll(
        await Future.wait([
          for (final target in const [
            ('Google', 'https://www.google.com/search?q=network&num=1'),
            ('GitHub', 'https://github.com/'),
            ('DeepSeek', 'https://www.deepseek.com/'),
          ])
            () async {
              ProbeResult? reply;
              try {
                reply = await routeProbe(
                  ProbeParams(url: target.$2, timeout: 8000, maxBody: 16384),
                );
              } catch (_) {
                reply = null;
              }
              return IpPortraitRoute(
                label: target.$1,
                url: target.$2,
                reply: reply,
              );
            }(),
        ]),
      );
    }
    return IpPortraitReport(
      checkedAt: DateTime.now(),
      routes: _cancelled ? const [] : List.unmodifiable(routes),
      exits: List.unmodifiable(exits),
      sources: List.unmodifiable(observations),
    );
  }
}
