import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:hotaru/common/ip_facts.dart';
import 'package:hotaru/models/ip_facts.dart';
import 'package:flutter_test/flutter_test.dart';

const _ip = '8.8.8.8';

class _Adapter implements HttpClientAdapter {
  final requests = <Uri>[];
  Map<String, Object?> location = {
    'ip': _ip,
    'country_code': 'US',
    'company': {'name': 'Google LLC', 'type': 'hosting', 'country_code': 'CA'},
    'asn': {'asn': 'AS15169', 'country_code': 'CA'},
    'privacy': {'is_hosting': true},
  };
  Map<String, Object?> registry = {
    'objectClassName': 'ip network',
    'startAddress': '8.8.8.0',
    'endAddress': '8.8.8.255',
    'ipVersion': 'v4',
    'country': 'US',
  };
  String score =
      '<title>8.8.8.8 ( Google LLC ) Fraud Risk</title>'
      '<div class="score_bar">0</div><div class="score">Fraud Score: 2</div>';
  int status = 200;
  String? redirect;
  Duration delay = Duration.zero;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options.uri);
    if (delay != Duration.zero) await Future<void>.delayed(delay);
    if (redirect != null) {
      return ResponseBody.fromString(
        '',
        302,
        headers: {
          'location': [redirect!],
        },
      );
    }
    return ResponseBody.fromString(switch (options.uri.host) {
      'iplocate.io' => jsonEncode(location),
      'rdap.org' => jsonEncode(registry),
      _ => score,
    }, status);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late _Adapter adapter;
  late Dio dio;
  setUp(() {
    adapter = _Adapter();
    dio = Dio()..httpClientAdapter = adapter;
  });
  tearDown(() => dio.close(force: true));
  Future<IpFacts> lookup({String ip = _ip, IpFacts? previous}) =>
      lookupIpFacts(dio, ip, cancelToken: CancelToken(), previous: previous);

  test(
    'three dimensions use their own evidence, not company or ASN country',
    () async {
      final facts = await lookup();
      expect(facts.origin, IpOrigin.native);
      expect(facts.attribute, IpAttribute.hosting);
      expect(facts.riskScore, 2);
      expect(facts.risk, IpRisk.low);
      expect(facts.organization, 'Google LLC');
      expect(facts.asn, 15169);
      expect(adapter.requests.map((r) => r.host).toSet(), {
        'iplocate.io',
        'rdap.org',
        'scamalytics.com',
      });
    },
  );

  test(
    'different IP block country is broadcast, missing RDAP country stays unknown',
    () async {
      adapter.registry['country'] = 'JP';
      expect((await lookup()).origin, IpOrigin.broadcast);
      adapter.registry.remove('country');
      final facts = await lookup();
      expect(facts.origin, IpOrigin.unknown);
      expect(facts.registryStatus, IpFactStatus.noData);
      expect(facts.attribute, IpAttribute.hosting);
      expect(facts.risk, IpRisk.low);
    },
  );

  for (final (start, end, version) in [
    ('9.9.9.0', '9.9.9.255', 'v4'),
    ('8.8.8.255', '8.8.8.0', 'v4'),
    ('::', 'ffff::', 'v6'),
    ('8.8.8.0', '8.8.8.255', 'v6'),
  ]) {
    test(
      'rejects unrelated or invalid registry range $start/$end/$version',
      () async {
        adapter.registry.addAll({
          'startAddress': start,
          'endAddress': end,
          'ipVersion': version,
        });
        expect((await lookup()).origin, IpOrigin.unknown);
      },
    );
  }

  test(
    'ignores entity country when the IP network country is absent',
    () async {
      adapter.registry.remove('country');
      adapter.registry['entities'] = [
        {'country': 'US'},
      ];
      expect((await lookup()).registeredCountry, isNull);
    },
  );

  test(
    'mismatched location response cannot supply type or registration comparison',
    () async {
      adapter.location['ip'] = '1.1.1.1';
      final facts = await lookup();
      expect(facts.attribute, IpAttribute.unknown);
      expect(facts.origin, IpOrigin.unknown);
      expect(facts.organization, isNull);
      expect(facts.riskScore, 2);
    },
  );

  for (final markup in [
    '<div class="score_bar">0</div>',
    '<div class="score">Fraud Score: 101</div>',
    '<div class="score">Fraud Score: -1</div>',
    '<div class="score">Fraud Score: 1.5</div>',
    '<div class="score">Fraud Score: 2</div><div class="score">Fraud Score: 99</div>',
    '<script>Fraud Score: 0</script>',
  ]) {
    test('does not invent a score from unsupported markup $markup', () async {
      adapter.score = '<title>8.8.8.8 ( Google LLC ) Fraud Risk</title>$markup';
      expect((await lookup()).risk, IpRisk.unknown);
    });
  }

  test('score page must belong to the queried address', () async {
    adapter.score = adapter.score.replaceAll('8.8.8.8', '1.1.1.1');
    expect((await lookup()).risk, IpRisk.unknown);
  });

  test('IPv6 textual compression does not create a false IP mismatch', () async {
    const ip = '2001:4860:4860::8888';
    adapter.location['ip'] = '2001:4860:4860:0000:0000:0000:0000:8888';
    adapter.registry.addAll({
      'startAddress': '2001:4860::',
      'endAddress': '2001:4860:ffff:ffff:ffff:ffff:ffff:ffff',
      'ipVersion': 'v6',
    });
    adapter.score =
        '<title>$ip ( Google LLC ) Fraud Risk</title><div class="score">Fraud Score: 2</div>';
    final facts = await lookup(ip: ip);
    expect(facts.origin, IpOrigin.native);
    expect(facts.riskScore, 2);
  });

  test(
    'a failed source is retried without consuming other sources daily quota',
    () async {
      adapter.registry.remove('country');
      final first = await lookup();
      final expired = first.copyWith(
        registryCheckedAt: DateTime.now().subtract(const Duration(minutes: 6)),
      );
      adapter.requests.clear();
      adapter.registry['country'] = 'US';
      final second = await lookup(previous: expired);
      expect(adapter.requests.map((r) => r.host), ['rdap.org']);
      expect(second.scoreCheckedAt, first.scoreCheckedAt);
      expect(second.locationCheckedAt, first.locationCheckedAt);
      expect(second.origin, IpOrigin.native);
      expect(second.riskScore, 2);
    },
  );

  test(
    'future or expired source timestamps cannot extend stale evidence',
    () async {
      final first = await lookup();
      final future = DateTime.now().add(const Duration(days: 2));
      adapter.requests.clear();
      await lookup(
        previous: first.copyWith(
          locationCheckedAt: future,
          registryCheckedAt: future,
          scoreCheckedAt: future,
        ),
      );
      expect(adapter.requests.length, 3);
      adapter.requests.clear();
      final old = DateTime.now().subtract(const Duration(days: 2));
      await lookup(
        previous: first.copyWith(
          locationCheckedAt: old,
          registryCheckedAt: old,
          scoreCheckedAt: old,
        ),
      );
      expect(adapter.requests.length, 3);
    },
  );

  test('rate limits and oversized HTML remain explicit unknowns', () async {
    adapter.status = 429;
    final facts = await lookup();
    expect(facts.scoreStatus, IpFactStatus.rateLimited);
    expect(facts.risk, IpRisk.unknown);
    adapter.status = 200;
    adapter.score = 'x' * (512 * 1024 + 1);
    expect((await lookup()).scoreStatus, IpFactStatus.unavailable);
  });

  test('redirects cannot downgrade to HTTP or embed credentials', () async {
    for (final target in [
      'http://scamalytics.com/ip/8.8.8.8',
      'https://name:password@example.org/',
    ]) {
      adapter.redirect = target;
      adapter.requests.clear();
      expect((await lookup()).risk, IpRisk.unknown);
      expect(adapter.requests.length, 3);
    }
  });

  test('cancellation cannot publish a new result', () async {
    final token = CancelToken()..cancel();
    await expectLater(
      lookupIpFacts(dio, _ip, cancelToken: token),
      throwsA(isA<DioException>()),
    );
  });

  for (final ip in [
    'localhost',
    '127.0.0.1',
    '10.0.0.1',
    '198.18.0.1',
    '::1',
    'fe80::1%eth0',
  ]) {
    test(
      'never sends a private or malformed address to third parties: $ip',
      () async {
        await expectLater(lookup(ip: ip), throwsFormatException);
        expect(adapter.requests, isEmpty);
      },
    );
  }
}
