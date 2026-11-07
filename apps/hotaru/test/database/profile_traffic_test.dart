import 'dart:io';

import 'package:drift/native.dart';
import 'package:hotaru/database/database.dart' as db;
import 'package:hotaru/models/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  group('checkpoint accounting', () {
    late db.Database database;
    setUp(() async {
      database = db.Database(NativeDatabase.memory());
      await database.profilesDao.setAll([
        Profile.normal(label: 'First').copyWith(id: 1),
        Profile.normal(label: 'Second').copyWith(id: 2),
      ]);
    });
    tearDown(() => database.close());

    Future<bool> record(String session, int up, int down, {int profile = 1}) =>
        database.profileTrafficDao.record(
          profileId: profile,
          sessionId: session,
          upload: up,
          download: down,
        );

    test(
      'initialization starts at zero and never resets observed totals',
      () async {
        await database.profileTrafficDao.initialize(1);
        expect(
          (await database.profileTrafficDao.query(1).getSingle()).upload,
          0,
        );
        await record('one', 100, 200);
        await database.profileTrafficDao.initialize(1);
        expect(
          (await database.profileTrafficDao.query(1).getSingle()).upload,
          100,
        );
        await database.profileTrafficDao.initialize(99);
        expect(
          await database.profileTrafficDao.query(99).getSingleOrNull(),
          isNull,
        );
      },
    );

    test(
      'zero starts an observed total without inventing subscription quota usage',
      () async {
        expect(await record('one', 0, 0), isTrue);
        final total = await database.profileTrafficDao.query(1).getSingle();
        expect(total.upload, 0);
        expect(total.download, 0);
        expect(await record('one', 0, 0), isFalse);
      },
    );

    test(
      'duplicates, out-of-order samples and restarts add only each session delta',
      () async {
        await record('one', 100, 200);
        await record('one', 125, 240);
        expect(await record('one', 100, 200), isFalse);
        await record('two', 10, 15);
        await record('one', 130, 250);
        expect(await record('one', 130, 250), isFalse);
        final total = await database.profileTrafficDao.query(1).getSingle();
        expect(total.upload, 140);
        expect(total.download, 265);
        await record('other-profile', 300, 400, profile: 2);
        expect(
          (await database.profileTrafficDao.query(1).getSingle()).upload,
          140,
        );
        expect(
          (await database.profileTrafficDao.query(2).getSingle()).upload,
          300,
        );
      },
    );

    test(
      'parallel observations serialize checkpoints and totals atomically',
      () async {
        await Future.wait([
          for (var i = 19; i >= 0; i--) record('one', i, i * 2),
          record('two', 100, 200),
        ]);
        final total = await database.profileTrafficDao.query(1).getSingle();
        expect(total.upload, 119);
        expect(total.download, 238);
      },
    );

    test(
      'a session cannot be reassigned to another selected profile',
      () async {
        await record('one', 100, 200);
        await expectLater(
          record('one', 300, 400, profile: 2),
          throwsStateError,
        );
        expect(
          await database.profileTrafficDao.query(2).getSingleOrNull(),
          isNull,
        );
        expect(
          (await database.profileTrafficDao.query(1).getSingle()).upload,
          100,
        );
      },
    );

    test(
      'a checkpoint write failure rolls back its total before retry',
      () async {
        await database.customStatement(
          "CREATE TRIGGER reject_traffic_checkpoint BEFORE INSERT ON profile_traffic_sessions BEGIN SELECT RAISE(ABORT, 'fixture_checkpoint_failure'); END",
        );
        await expectLater(
          record('one', 100, 200),
          throwsA(isA<SqliteException>()),
        );
        expect(
          await database.profileTrafficDao.query(1).getSingleOrNull(),
          isNull,
        );
        expect(await database.profileTrafficSessions.count.getSingle(), 0);
        await database.customStatement(
          'DROP TRIGGER reject_traffic_checkpoint',
        );
        await record('one', 100, 200);
        expect(
          (await database.profileTrafficDao.query(1).getSingle()).upload,
          100,
        );
      },
    );

    test(
      'deleted profiles cascade totals/checkpoints and ignore late responses',
      () async {
        await record('one', 100, 200);
        await database.profilesDao.setAll([
          Profile.normal(label: 'Second').copyWith(id: 2),
        ]);
        expect(await database.profileTrafficTotals.count.getSingle(), 0);
        expect(await database.profileTrafficSessions.count.getSingle(), 0);
        expect(await record('one', 200, 400), isFalse);
        expect(await record('missing', 1, 1, profile: 99), isFalse);
      },
    );

    test(
      'invalid input and storage overflow preserve both sides of the transaction',
      () async {
        for (final session in ['', 'a\nb', 'x' * 129]) {
          expect(() => record(session, 1, 1), throwsArgumentError);
        }
        expect(() => record('one', -1, 1), throwsArgumentError);
        expect(() => record('one', 1, -1), throwsArgumentError);
        const maximum = 0x7fffffffffffffff;
        await record('one', maximum, 0);
        await expectLater(record('overflow', 1, 0), throwsRangeError);
        await expectLater(record('combined-overflow', 0, 1), throwsRangeError);
        expect(
          (await database.profileTrafficDao.query(1).getSingle()).upload,
          maximum,
        );
        expect(await database.profileTrafficSessions.count.getSingle(), 1);
      },
    );
  });

  test(
    'checkpoints survive database reopen without recounting prior sessions',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'hotaru-profile-traffic-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/db.sqlite');
      final first = db.Database(NativeDatabase(file));
      await first.profilesDao.setAll([Profile.normal().copyWith(id: 1)]);
      await first.profileTrafficDao.record(
        profileId: 1,
        sessionId: 'one',
        upload: 100,
        download: 200,
      );
      await first.close();
      final reopened = db.Database(NativeDatabase(file));
      addTearDown(reopened.close);
      expect(
        await reopened.profileTrafficDao.record(
          profileId: 1,
          sessionId: 'one',
          upload: 100,
          download: 200,
        ),
        isFalse,
      );
      await reopened.profileTrafficDao.record(
        profileId: 1,
        sessionId: 'one',
        upload: 120,
        download: 240,
      );
      final total = await reopened.profileTrafficDao.query(1).getSingle();
      expect(total.upload, 120);
      expect(total.download, 240);
    },
  );

  for (final from in [21, 22]) {
    for (final present in ['none', 'totals', 'both']) {
      test(
        'released/development schema $from with $present traffic tables upgrades idempotently',
        () async {
          final dir = await Directory.systemTemp.createTemp(
            'hotaru-traffic-migration-',
          );
          addTearDown(() => dir.delete(recursive: true));
          final file = File('${dir.path}/db.sqlite');
          final first = db.Database(NativeDatabase(file));
          await first.profilesDao.setAll([
            Profile.normal(label: 'Kept').copyWith(id: 1),
          ]);
          await first.customStatement(
            "INSERT INTO ip_qualities VALUES ('8.8.8.8', '{}', 0)",
          );
          if (present == 'both') {
            await first.profileTrafficDao.record(
              profileId: 1,
              sessionId: 'one',
              upload: 42,
              download: 64,
            );
          }
          await first.close();
          final raw = sqlite3.open(file.path);
          if (present != 'both') {
            raw.execute('DROP TABLE profile_traffic_sessions');
          }
          if (present == 'none') {
            raw.execute('DROP TABLE profile_traffic_totals');
          }
          raw.execute('PRAGMA user_version = $from');
          raw.close();
          final upgraded = db.Database(NativeDatabase(file));
          addTearDown(upgraded.close);
          expect((await upgraded.profilesDao.get(1))!.label, 'Kept');
          expect(
            await upgraded.profileTrafficSessions.count.getSingle(),
            present == 'both' ? 1 : 0,
          );
          expect(
            (await upgraded.profileTrafficDao.query(1).getSingleOrNull())
                ?.upload,
            present == 'both' ? 42 : null,
          );
          expect(
            (await upgraded.customSelect('SELECT ip FROM ip_qualities').get())
                .single
                .read<String>('ip'),
            '8.8.8.8',
          );
          expect(
            (await upgraded.customSelect('PRAGMA user_version').get()).single
                .read<int>('user_version'),
            23,
          );
        },
      );
    }
  }
}
