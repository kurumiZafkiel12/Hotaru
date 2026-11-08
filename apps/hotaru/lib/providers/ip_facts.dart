import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:hotaru/common/ip_facts.dart';
import 'package:hotaru/common/request.dart';
import 'package:hotaru/database/database.dart';
import 'package:hotaru/models/ip_facts.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'generated/ip_facts.g.dart';

Duration? _noRetry(int count, Object error) => null;

@Riverpod(retry: _noRetry)
Future<IpFacts> ipFacts(Ref ref, String ip) async {
  final canonical = InternetAddress.tryParse(ip)?.address ?? ip;
  IpFacts? cached;
  try {
    cached = (await database.ipFactsDao.cached(canonical))?.facts;
  } catch (_) {
    cached = null;
  }
  if (cached?.ip != canonical) cached = null;
  if (!ref.mounted) throw StateError('IP facts request disposed');
  final now = DateTime.now().toUtc();
  IpFacts facts;
  if (!ref.isRefresh &&
      cached != null &&
      cached.checkedAt.isBefore(now) &&
      cached.expiresAt.isAfter(now)) {
    facts = cached;
  } else {
    final cancelToken = CancelToken();
    ref.onDispose(cancelToken.cancel);
    facts = await lookupIpFacts(
      request.dio,
      canonical,
      cancelToken: cancelToken,
      previous: ref.isRefresh ? null : cached,
    );
    if (!ref.mounted) throw StateError('IP facts request disposed');
    try {
      await database.ipFactsDao.put(facts);
    } catch (_) {}
  }
  if (ref.mounted) {
    final link = ref.keepAlive();
    final delay = facts.expiresAt.difference(DateTime.now().toUtc());
    final timer = Timer(delay.isNegative ? Duration.zero : delay, () {
      link.close();
      ref.invalidateSelf();
    });
    ref.onDispose(timer.cancel);
  }
  return facts;
}
