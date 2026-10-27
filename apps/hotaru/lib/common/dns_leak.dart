import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import 'network_diagnostics.dart';

class DnsResolverReceipt {
  const DnsResolverReceipt({
    required this.ip,
    required this.country,
    required this.organization,
    this.hostname = '',
  });

  final String ip;
  final String country;
  final String organization;
  final String hostname;

  DnsResolverReceipt withHostname(String value) => DnsResolverReceipt(
    ip: ip,
    country: country,
    organization: organization,
    hostname: value,
  );

  bool get domesticIsp => RegExp(
    r'china\s*(telecom|unicom|mobile)|chinanet|中国电信|中国联通|中国移动|AS(4134|4837|4809|9929|9808)\b',
    caseSensitive: false,
  ).hasMatch(organization);
}

/// The DNS verdict, judged against the exit the traffic should use:
/// a resolver answering from another country means the query left by
/// a path the exit does not cover.
enum DnsLeakVerdict { leaking, clean, inconclusive }

DnsLeakVerdict judgeDnsLeak(
  List<DnsResolverReceipt> resolvers,
  String? exitCountry,
) {
  if (resolvers.isEmpty || exitCountry == null || exitCountry.isEmpty) {
    return DnsLeakVerdict.inconclusive;
  }
  var judged = 0;
  for (final resolver in resolvers) {
    if (resolver.country.isEmpty) continue;
    judged++;
    if (resolver.country.toUpperCase() != exitCountry.toUpperCase()) {
      return DnsLeakVerdict.leaking;
    }
  }
  return judged == resolvers.length
      ? DnsLeakVerdict.clean
      : DnsLeakVerdict.inconclusive;
}

/// Best-effort reverse names for the resolvers, for the table's
/// hostname column; a resolver without one keeps an empty name.
Future<List<DnsResolverReceipt>> enrichResolverHostnames(
  List<DnsResolverReceipt> receipts, {
  Future<String> Function(InternetAddress)? reverse,
}) async {
  final lookup = reverse ?? (address) async => (await address.reverse()).host;
  return Future.wait([
    for (final receipt in receipts)
      () async {
        try {
          final host = await lookup(
            InternetAddress(receipt.ip),
          ).timeout(const Duration(seconds: 2));
          return receipt.withHostname(host);
        } catch (_) {
          return receipt;
        }
      }(),
  ]);
}

List<DnsResolverReceipt> parseDnsResolverReceipts(Object? data) {
  final decoded = data is String ? jsonDecode(data) : data;
  if (decoded is! List) {
    throw const FormatException('Invalid DNS receipt response');
  }
  final receipts = <String, DnsResolverReceipt>{};
  for (final row in decoded) {
    if (row is! Map || row['type'] != 'dns') continue;
    final address = InternetAddress.tryParse('${row['ip'] ?? ''}');
    if (address == null || !isPublicProbeAddress(address)) continue;
    receipts[address.address] = DnsResolverReceipt(
      ip: address.address,
      country: '${row['country'] ?? ''}'.toUpperCase(),
      organization: '${row['asn'] ?? ''}',
    );
  }
  return receipts.values.toList();
}

class DnsLeakProbe {
  DnsLeakProbe({
    required this.dio,
    Future<List<InternetAddress>> Function(String)? lookup,
  }) : lookup = lookup ?? InternetAddress.lookup;

  final Dio dio;
  final Future<List<InternetAddress>> Function(String) lookup;

  Future<List<DnsResolverReceipt>> run(
    CancelToken cancelToken, {
    int probes = 20,
  }) async {
    final options = Options(
      responseType: ResponseType.plain,
      receiveTimeout: const Duration(seconds: 8),
      sendTimeout: const Duration(seconds: 8),
    );
    final lease = await dio.get<String>(
      'https://bash.ws/id',
      options: options,
      cancelToken: cancelToken,
    );
    final id = lease.data?.trim() ?? '';
    if (!RegExp(r'^[A-Za-z0-9-]{1,64}$').hasMatch(id)) {
      throw const FormatException('Invalid DNS probe lease');
    }
    var cursor = 1;
    Future<void> worker() async {
      while (!cancelToken.isCancelled && cursor <= probes) {
        final index = cursor++;
        try {
          await lookup(
            '$index.$id.bash.ws',
          ).timeout(const Duration(seconds: 5));
        } on TimeoutException {
          continue;
        } on SocketException {
          // NXDOMAIN still leaves an authoritative receipt.
        }
      }
    }

    await Future.wait(List.generate(4, (_) => worker()));
    if (cancelToken.isCancelled) {
      throw DioException.requestCancelled(
        requestOptions: RequestOptions(),
        reason: 'cancelled',
      );
    }
    for (var attempt = 0; attempt < 3; attempt++) {
      final response = await dio.get<String>(
        'https://bash.ws/dnsleak/test/$id?json=2',
        options: options,
        cancelToken: cancelToken,
      );
      final receipts = parseDnsResolverReceipts(response.data);
      if (receipts.isNotEmpty || attempt == 2) return receipts;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    return const [];
  }
}
