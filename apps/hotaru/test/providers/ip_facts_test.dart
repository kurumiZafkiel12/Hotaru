import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:hotaru/common/request.dart';
import 'package:hotaru/database/database.dart' as db;
import 'package:hotaru/models/ip_facts.dart';
import 'package:hotaru/providers/ip_facts.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod/riverpod.dart';

class _Adapter implements HttpClientAdapter {
  int requests = 0;
  bool fail = false;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    if (fail) return ResponseBody.fromString('', 503);
    return ResponseBody.fromString(
      options.uri.host == 'iplocate.io'
          ? jsonEncode({
              'ip': '8.8.8.8',
              'country_code': 'US',
              'company': {'type': 'hosting'},
            })
          : options.uri.host == 'rdap.org'
          ? jsonEncode({
              'objectClassName': 'ip network',
              'startAddress': '8.8.8.0',
              'endAddress': '8.8.8.255',
              'ipVersion': 'v4',
              'country': 'US',
            })
          : '<title>8.8.8.8 ( Google LLC ) Fraud Risk</title><div class="score">Fraud Score: 3</div>',
      200,
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  final provider = ipFactsProvider('8.8.8.8');
  late db.Database originalDatabase;
  late db.Database database;
  late HttpClientAdapter originalAdapter;
  late _Adapter adapter;
  late ProviderContainer container;
  setUp(() {
    originalDatabase = db.database;
    originalAdapter = request.dio.httpClientAdapter;
    database = db.Database(NativeDatabase.memory());
    db.database = database;
    adapter = _Adapter();
    request.dio.httpClientAdapter = adapter;
    container = ProviderContainer();
    container.listen(provider, (_, _) {});
  });
  tearDown(() async {
    container.dispose();
    await database.close();
    db.database = originalDatabase;
    request.dio.httpClientAdapter = originalAdapter;
  });

  test('concurrent consumers share one result and persist it', () async {
    final hold = container.listen(provider, (_, _) {});
    final values = await Future.wait([
      container.read(provider.future),
      container.read(provider.future),
    ]);
    expect(values.first, values.last);
    expect(values.first.riskScore, 3);
    expect(adapter.requests, 3);
    expect((await database.ipFactsDao.cached('8.8.8.8'))?.facts, values.first);
    hold.close();
    expect(await container.read(provider.future), values.first);
    expect(adapter.requests, 3);
  });

  test(
    'process restart reuses persistent data; explicit refresh asks all sources',
    () async {
      final first = await container.read(provider.future);
      container.dispose();
      container = ProviderContainer();
      container.listen(provider, (_, _) {});
      expect(await container.read(provider.future), first);
      expect(adapter.requests, 3);
      container.invalidate(provider);
      expect((await container.read(provider.future)).riskScore, 3);
      expect(adapter.requests, 6);
    },
  );

  test('a corrupted cache row cannot return facts for another IP', () async {
    final now = DateTime.now().toUtc();
    await database
        .into(database.ipFactRecords)
        .insert(
          db.IpFactRecordsCompanion.insert(
            ip: '8.8.8.8',
            checkedAt: now,
            facts: IpFacts(
              ip: '1.1.1.1',
              checkedAt: now,
              locationCheckedAt: now,
              registryCheckedAt: now,
              scoreCheckedAt: now,
              riskScore: 0,
              locationStatus: IpFactStatus.available,
              registryStatus: IpFactStatus.available,
              scoreStatus: IpFactStatus.available,
            ),
          ),
        );
    final facts = await container.read(provider.future);
    expect(facts.ip, '8.8.8.8');
    expect(facts.riskScore, 3);
    expect(adapter.requests, 3);
  });

  test('partial failure is cached without pretending risk is low', () async {
    adapter.fail = true;
    final facts = await container.read(provider.future);
    expect(facts.risk, IpRisk.unknown);
    expect(facts.origin, IpOrigin.unknown);
    container.dispose();
    container = ProviderContainer();
    container.listen(provider, (_, _) {});
    expect(await container.read(provider.future), facts);
    expect(adapter.requests, 3);
  });
}
