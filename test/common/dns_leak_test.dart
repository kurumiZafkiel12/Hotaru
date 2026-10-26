import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:hotaru/common/dns_leak.dart';
import 'package:flutter_test/flutter_test.dart';

class _ReceiptAdapter implements HttpClientAdapter {
  String lease = 'controlled-lease';
  final calls = <Uri>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls.add(options.uri);
    return ResponseBody.fromString(
      options.uri.path == '/id'
          ? lease
          : jsonEncode([
              {
                'type': 'dns',
                'ip': '8.8.8.8',
                'country': 'us',
                'asn': 'AS15169 Google',
              },
              {'type': 'conclusion', 'ip': 'No leak'},
            ]),
      200,
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test(
    'authoritative receipts exclude conclusions, invalid and fake-IP answers',
    () {
      final records = parseDnsResolverReceipts([
        {
          'type': 'dns',
          'ip': '1.1.1.1',
          'country': 'au',
          'asn': 'AS13335 Cloudflare',
        },
        {
          'type': 'dns',
          'ip': '1.1.1.1',
          'country': 'au',
          'asn': 'AS13335 Cloudflare',
        },
        {'type': 'ip', 'ip': '8.8.8.8'},
        {'type': 'dns', 'ip': '198.18.0.1'},
        {'type': 'dns', 'ip': '192.168.1.1'},
        {'type': 'dns', 'ip': 'invalid'},
        {'type': 'conclusion', 'text': 'No leak'},
      ]);
      expect(records, hasLength(1));
      expect(records.single.ip, '1.1.1.1');
      expect(records.single.country, 'AU');
      expect(records.single.domesticIsp, isFalse);
      expect(
        () => parseDnsResolverReceipts({'error': 'unavailable'}),
        throwsFormatException,
      );
      expect(
        const DnsResolverReceipt(
          ip: '8.8.8.8',
          country: 'CN',
          organization: 'AS4134 China Telecom',
        ).domesticIsp,
        isTrue,
      );
      expect(
        const DnsResolverReceipt(
          ip: '8.8.8.8',
          country: 'CN',
          organization: 'AS4809',
        ).domesticIsp,
        isTrue,
      );
    },
  );

  test(
    'sends sixteen lease-specific DNS queries with at most four outstanding',
    () async {
      final adapter = _ReceiptAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      addTearDown(dio.close);
      final names = <String>[];
      var active = 0;
      var peak = 0;
      final probe = DnsLeakProbe(
        dio: dio,
        lookup: (name) async {
          names.add(name);
          active++;
          if (active > peak) peak = active;
          await Future<void>.delayed(const Duration(milliseconds: 2));
          active--;
          throw const SocketException('NXDOMAIN');
        },
      );
      final result = await probe.run(CancelToken());
      expect(names.toSet(), hasLength(16));
      expect(
        names.every((name) => name.endsWith('.controlled-lease.bash.ws')),
        isTrue,
      );
      expect(peak, lessThanOrEqualTo(4));
      expect(result.single.ip, '8.8.8.8');
      expect(adapter.calls.last.path, '/dnsleak/test/controlled-lease');
      expect(adapter.calls.last.queryParameters['json'], '2');
    },
  );

  test('rejects a malformed lease before any DNS request', () async {
    final adapter = _ReceiptAdapter()..lease = '../foreign.example';
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(dio.close);
    var requests = 0;
    final probe = DnsLeakProbe(
      dio: dio,
      lookup: (_) async {
        requests++;
        return [];
      },
    );
    await expectLater(probe.run(CancelToken()), throwsFormatException);
    expect(requests, 0);
    expect(adapter.calls, hasLength(1));
  });

  test(
    'cancellation stops DNS queueing and does not request results',
    () async {
      final adapter = _ReceiptAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      addTearDown(dio.close);
      final entered = Completer<void>();
      final release = Completer<List<InternetAddress>>();
      var requested = 0;
      final token = CancelToken();
      final probe = DnsLeakProbe(
        dio: dio,
        lookup: (_) {
          if (++requested == 4) entered.complete();
          return release.future;
        },
      );
      final pending = probe.run(token);
      final checked = expectLater(pending, throwsA(isA<DioException>()));
      await entered.future;
      token.cancel();
      release.complete([]);
      await checked;
      expect(requested, 4);
      expect(adapter.calls, hasLength(1));
    },
  );
}
