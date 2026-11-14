import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:hotaru/models/ip_facts.dart';
import 'package:hotaru/common/network_diagnostics.dart';
import 'package:hotaru/common/country_names.dart';
import 'package:html/parser.dart' as html;

const _bodyLimit = 512 * 1024;

Future<IpFacts> lookupIpFacts(
  Dio dio,
  String ip, {
  required CancelToken cancelToken,
  IpFacts? previous,
  Duration timeout = const Duration(seconds: 12),
}) async {
  final address = InternetAddress.tryParse(ip);
  if (address == null || !isPublicProbeAddress(address) || ip.contains('%')) {
    throw const FormatException('Invalid public IP address');
  }
  final canonical = address.address;
  final now = DateTime.now().toUtc();
  bool fresh(DateTime? at, IpFactStatus status) =>
      previous?.ip == canonical &&
      at != null &&
      !at.isAfter(now) &&
      now.difference(at) <
          (status == IpFactStatus.available
              ? const Duration(days: 1)
              : const Duration(minutes: 5));
  final answers = await Future.wait<_Reply?>([
    if (fresh(
      previous?.locationCheckedAt,
      previous?.locationStatus ?? IpFactStatus.unavailable,
    ))
      Future.value(null)
    else
      _query(
        dio,
        Uri.https('iplocate.io', '/api/lookup/$canonical'),
        cancelToken,
        timeout,
      ),
    if (fresh(
      previous?.registryCheckedAt,
      previous?.registryStatus ?? IpFactStatus.unavailable,
    ))
      Future.value(null)
    else
      _query(
        dio,
        Uri.https('rdap.org', '/ip/$canonical'),
        cancelToken,
        timeout,
      ),
    if (fresh(
      previous?.scoreCheckedAt,
      previous?.scoreStatus ?? IpFactStatus.unavailable,
    ))
      Future.value(null)
    else
      _query(
        dio,
        Uri.https('scamalytics.com', '/ip/$canonical'),
        cancelToken,
        timeout,
      ),
  ]);
  if (cancelToken.isCancelled) throw cancelToken.cancelError!;
  final facts = await compute(_parse, (canonical, now, answers, previous));
  if (cancelToken.isCancelled) throw cancelToken.cancelError!;
  return facts;
}

typedef _Reply = ({String? body, IpFactStatus status});

Future<_Reply> _query(
  Dio dio,
  Uri uri,
  CancelToken parent,
  Duration timeout,
) async {
  final token = CancelToken();
  final timer = Timer(timeout, token.cancel);
  var done = false;
  unawaited(
    parent.whenCancel.then((_) {
      if (!done) token.cancel();
    }),
  );
  try {
    for (var hop = 0; hop < 5; hop++) {
      final response = await dio.getUri<ResponseBody>(
        uri,
        cancelToken: token,
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: false,
          validateStatus: (_) => true,
          receiveTimeout: timeout,
          sendTimeout: timeout,
        ),
      );
      final status = response.statusCode;
      final body = response.data;
      if (body == null) return (body: null, status: IpFactStatus.unavailable);
      if (status == 301 ||
          status == 302 ||
          status == 303 ||
          status == 307 ||
          status == 308) {
        await body.stream.listen(null).cancel();
        final target = uri.resolve(response.headers.value('location') ?? '');
        if (target.scheme != 'https' ||
            target.host.isEmpty ||
            target.userInfo.isNotEmpty) {
          break;
        }
        uri = target;
        continue;
      }
      if (status != 200) {
        await body.stream.listen(null).cancel();
        return (
          body: null,
          status: status == 429
              ? IpFactStatus.rateLimited
              : IpFactStatus.unavailable,
        );
      }
      final bytes = <int>[];
      await for (final chunk in body.stream) {
        if (bytes.length + chunk.length > _bodyLimit) {
          token.cancel();
          return (body: null, status: IpFactStatus.unavailable);
        }
        bytes.addAll(chunk);
      }
      return (body: utf8.decode(bytes), status: IpFactStatus.available);
    }
  } catch (_) {
    return (body: null, status: IpFactStatus.unavailable);
  } finally {
    done = true;
    timer.cancel();
  }
  return (body: null, status: IpFactStatus.unavailable);
}

IpFacts _parse((String, DateTime, List<_Reply?>, IpFacts?) input) {
  final (ip, checkedAt, replies, previous) = input;
  var facts =
      (previous?.ip == ip ? previous! : IpFacts(ip: ip, checkedAt: checkedAt))
          .copyWith(checkedAt: checkedAt);
  final locationReply = replies[0];
  if (locationReply != null) {
    facts = facts.copyWith(
      locationCheckedAt: checkedAt,
      locationStatus: locationReply.status,
      geoCountry: null,
      attribute: IpAttribute.unknown,
      organization: null,
      asn: null,
    );
    final location = _json(locationReply.body);
    if (location != null && _sameIp(location['ip'], ip)) {
      final company = _object(location['company']);
      final asn = _object(location['asn']);
      final privacy = _object(location['privacy']);
      final attribute = privacy['is_hosting'] == true
          ? IpAttribute.hosting
          : switch (company['type']) {
              'hosting' => IpAttribute.hosting,
              'isp' || 'residential' => IpAttribute.residential,
              'mobile' => IpAttribute.mobile,
              'business' => IpAttribute.business,
              _ => IpAttribute.unknown,
            };
      facts = facts.copyWith(
        geoCountry: _country(location['country_code']),
        attribute: attribute,
        organization: _text(company['name']) ?? _text(asn['name']),
        asn: _asn(asn['asn']),
      );
    } else if (locationReply.body != null) {
      facts = facts.copyWith(locationStatus: IpFactStatus.noData);
    }
  }
  final registryReply = replies[1];
  if (registryReply != null) {
    facts = facts.copyWith(
      registryCheckedAt: checkedAt,
      registryStatus: registryReply.status,
      registeredCountry: null,
    );
    final registry = _json(registryReply.body);
    if (registry != null &&
        registry['objectClassName'] == 'ip network' &&
        _contains(registry, ip)) {
      final country = _country(registry['country']);
      facts = facts.copyWith(
        registeredCountry: country,
        registryStatus: country == null
            ? IpFactStatus.noData
            : IpFactStatus.available,
      );
    } else if (registryReply.body != null) {
      facts = facts.copyWith(registryStatus: IpFactStatus.noData);
    }
  }
  final scoreReply = replies[2];
  if (scoreReply != null) {
    final score = _score(scoreReply.body, ip);
    facts = facts.copyWith(
      scoreCheckedAt: checkedAt,
      riskScore: score,
      scoreStatus: score != null
          ? IpFactStatus.available
          : scoreReply.body != null
          ? IpFactStatus.noData
          : scoreReply.status,
    );
  }
  return facts;
}

int? _score(String? body, String ip) {
  if (body == null) return null;
  final document = html.parse(body);
  final title = document.querySelector('title')?.text.trim() ?? '';
  final titleIp = title.split(RegExp(r'\s')).first;
  if (!_sameIp(titleIp, ip) || !title.endsWith('Fraud Risk')) return null;
  final scores = document.querySelectorAll('.score');
  if (scores.length != 1) return null;
  final match = RegExp(
    r'^Fraud Score:\s*(\d{1,3})$',
  ).firstMatch(scores.single.text.trim());
  final value = int.tryParse(match?.group(1) ?? '');
  return value != null && value >= 0 && value <= 100 ? value : null;
}

Map<String, dynamic>? _json(String? value) {
  if (value == null) return null;
  try {
    return _object(jsonDecode(value));
  } catch (_) {
    return null;
  }
}

Map<String, dynamic> _object(Object? value) =>
    value is Map<String, dynamic> ? value : const {};
String? _text(Object? value) =>
    value is String && value.trim().isNotEmpty ? value.trim() : null;
String? _country(Object? value) {
  final country = _text(value)?.toUpperCase();
  return country != null &&
          countryName(country, 'en') != null &&
          country != 'ZZ'
      ? country
      : null;
}

int? _asn(Object? value) {
  final number = value is int
      ? value
      : int.tryParse(_text(value)?.replaceFirst('AS', '') ?? '');
  return number != null && number > 0 && number <= 4294967295 ? number : null;
}

bool _sameIp(Object? value, String ip) {
  final address = value is String ? InternetAddress.tryParse(value) : null;
  final queried = InternetAddress.tryParse(ip);
  return address != null &&
      queried != null &&
      listEquals(address.rawAddress, queried.rawAddress);
}

bool _contains(Map<String, dynamic> network, String ip) {
  final start = InternetAddress.tryParse(_text(network['startAddress']) ?? '');
  final end = InternetAddress.tryParse(_text(network['endAddress']) ?? '');
  final address = InternetAddress.tryParse(ip)!;
  if (start == null ||
      end == null ||
      start.type != address.type ||
      end.type != address.type ||
      network['ipVersion'] !=
          (address.type == InternetAddressType.IPv4 ? 'v4' : 'v6')) {
    return false;
  }
  BigInt number(InternetAddress a) =>
      a.rawAddress.fold(BigInt.zero, (v, b) => (v << 8) + BigInt.from(b));
  final target = number(address);
  return number(start) <= target && target <= number(end);
}
