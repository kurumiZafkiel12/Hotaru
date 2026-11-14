import 'dart:io';

import 'package:drift/native.dart';
import 'package:hotaru/database/database.dart' as db;
import 'package:hotaru/models/ip_facts.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test(
    'cache round trips source timestamps, prunes stale data and caps growth',
    () async {
      final database = db.Database(NativeDatabase.memory());
      addTearDown(database.close);
      final now = DateTime.now().toUtc();
      final stale = IpFacts(
        ip: '1.1.1.1',
        checkedAt: now.subtract(const Duration(days: 3)),
      );
      await database.ipFactsDao.put(stale);
      final latest = IpFacts(
        ip: '8.8.8.8',
        checkedAt: now,
        scoreCheckedAt: now,
        riskScore: 3,
        scoreStatus: IpFactStatus.available,
      );
      await database.ipFactsDao.put(latest);
      expect((await database.ipFactsDao.cached(latest.ip))?.facts, latest);
      expect(await database.ipFactsDao.cached(stale.ip), isNull);
      await database.batch(
        (batch) => batch.insertAll(database.ipFactRecords, [
          for (var i = 0; i < 520; i++)
            db.IpFactRecordsCompanion.insert(
              ip: 'sample-$i',
              facts: IpFacts(ip: 'sample-$i', checkedAt: now),
              checkedAt: now,
            ),
        ]),
      );
      final newest = latest.copyWith(
        checkedAt: now.add(const Duration(seconds: 1)),
      );
      await database.ipFactsDao.put(newest);
      expect(await database.ipFactRecords.count.getSingle(), 512);
      expect((await database.ipFactsDao.cached(latest.ip))?.facts, newest);
    },
  );

  for (final alreadyPresent in [false, true]) {
    test(
      'upgrade from released schema 21 preserves old records; table already present: $alreadyPresent',
      () async {
        final dir = Directory.systemTemp.createTempSync(
          'hotaru-ip-facts-migration-',
        );
        addTearDown(() => dir.deleteSync(recursive: true));
        final file = File('${dir.path}/db.sqlite');
        final first = db.Database(NativeDatabase(file));
        await first.customSelect('SELECT 1').get();
        await first.customStatement(
          "INSERT INTO ip_qualities VALUES ('8.8.8.8', '{}', 0)",
        );
        await first.close();
        final raw = sqlite3.open(file.path);
        if (!alreadyPresent) raw.execute('DROP TABLE ip_fact_records');
        raw.execute('PRAGMA user_version = 21');
        raw.close();
        final upgraded = db.Database(NativeDatabase(file));
        addTearDown(upgraded.close);
        expect(await upgraded.ipFactRecords.count.getSingle(), 0);
        expect(
          (await upgraded.customSelect('SELECT ip FROM ip_qualities').get())
              .single
              .read<String>('ip'),
          '8.8.8.8',
        );
        expect(
          (await upgraded.customSelect('PRAGMA user_version').get()).single
              .read<int>('user_version'),
          upgraded.schemaVersion,
        );
      },
    );
  }
}
