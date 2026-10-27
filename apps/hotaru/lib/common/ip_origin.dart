import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:hotaru/enum/enum.dart';

/// Asks two independent geolocation services for [ip]'s country and
/// compares them. One answer alone proves nothing, so a single success
/// still reads as [IpOrigin.unknown].
Future<IpOrigin> lookupIpOrigin(
  Dio dio,
  String ip, {
  required CancelToken cancelToken,
  Duration timeout = const Duration(seconds: 8),
}) async {
  final countries = await Future.wait([
    _countryOf(dio, 'https://ipwho.is/$ip', cancelToken, timeout),
    _countryOf(dio, 'https://api.ip.sb/geoip/$ip', cancelToken, timeout),
  ]);
  final first = countries[0];
  final second = countries[1];
  if (first == null || second == null) {
    return IpOrigin.unknown;
  }
  return first == second ? IpOrigin.native : IpOrigin.broadcast;
}

Future<String?> _countryOf(
  Dio dio,
  String url,
  CancelToken cancelToken,
  Duration timeout,
) async {
  try {
    final response = await dio
        .get<String>(
          url,
          cancelToken: cancelToken,
          options: Options(
            responseType: ResponseType.plain,
            validateStatus: (_) => true,
          ),
        )
        .timeout(timeout);
    if (response.statusCode != 200) {
      return null;
    }
    final json = jsonDecode(response.data ?? '') as Map<String, dynamic>;
    final code = json['country_code'];
    return code is String && code.length == 2 ? code.toUpperCase() : null;
  } catch (_) {
    return null;
  }
}
