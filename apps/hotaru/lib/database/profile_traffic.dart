part of 'database.dart';

@DataClassName('ProfileTrafficTotal')
class ProfileTrafficTotals extends Table {
  IntColumn get profileId =>
      integer().references(Profiles, #id, onDelete: KeyAction.cascade)();
  IntColumn get upload => integer()();
  IntColumn get download => integer()();

  @override
  Set<Column> get primaryKey => {profileId};
}

@DataClassName('ProfileTrafficSession')
class ProfileTrafficSessions extends Table {
  TextColumn get sessionId => text()();
  IntColumn get profileId =>
      integer().references(Profiles, #id, onDelete: KeyAction.cascade)();
  IntColumn get upload => integer()();
  IntColumn get download => integer()();

  @override
  Set<Column> get primaryKey => {sessionId};
}

@DriftAccessor(tables: [Profiles, ProfileTrafficTotals, ProfileTrafficSessions])
class ProfileTrafficDao extends DatabaseAccessor<Database>
    with _$ProfileTrafficDaoMixin {
  ProfileTrafficDao(super.attachedDatabase);

  Future<void> initialize(int profileId) => transaction(() async {
    final profile =
        await (selectOnly(profiles)
              ..addColumns([profiles.id])
              ..where(profiles.id.equals(profileId)))
            .getSingleOrNull();
    if (profile == null) return;
    await into(profileTrafficTotals).insert(
      ProfileTrafficTotalsCompanion.insert(
        profileId: Value(profileId),
        upload: 0,
        download: 0,
      ),
      mode: InsertMode.insertOrIgnore,
    );
  });

  Selectable<ProfileTrafficTotal> query([int? profileId]) =>
      select(profileTrafficTotals)..where(
        (t) => profileId == null
            ? const Constant(true)
            : t.profileId.equals(profileId),
      );

  Future<bool> record({
    required int profileId,
    required String sessionId,
    required int upload,
    required int download,
  }) {
    if (profileId < 0 ||
        !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(sessionId) ||
        upload < 0 ||
        download < 0) {
      throw ArgumentError('Invalid profile traffic observation');
    }
    return transaction(() async {
      final profile =
          await (selectOnly(profiles)
                ..addColumns([profiles.id])
                ..where(profiles.id.equals(profileId)))
              .getSingleOrNull();
      if (profile == null) return false;
      final previous = await (select(
        profileTrafficSessions,
      )..where((t) => t.sessionId.equals(sessionId))).getSingleOrNull();
      if (previous != null && previous.profileId != profileId) {
        throw StateError('A core session cannot belong to two profiles');
      }
      final previousUp = previous?.upload ?? 0;
      final previousDown = previous?.download ?? 0;
      final nextUp = upload > previousUp ? upload : previousUp;
      final nextDown = download > previousDown ? download : previousDown;
      if (previous != null &&
          nextUp == previous.upload &&
          nextDown == previous.download) {
        return false;
      }
      final total = await query(profileId).getSingleOrNull();
      if (previous != null && total == null) {
        throw StateError('Profile traffic total is missing');
      }
      final deltaUp = nextUp - (previous?.upload ?? 0);
      final deltaDown = nextDown - (previous?.download ?? 0);
      const maximum = 0x7fffffffffffffff;
      if (deltaUp > maximum - (total?.upload ?? 0) ||
          deltaDown > maximum - (total?.download ?? 0)) {
        throw RangeError('Profile traffic total exceeds storage range');
      }
      final totalUp = (total?.upload ?? 0) + deltaUp;
      final totalDown = (total?.download ?? 0) + deltaDown;
      if (totalUp > maximum - totalDown) {
        throw RangeError('Combined profile traffic exceeds storage range');
      }
      await into(profileTrafficTotals).insertOnConflictUpdate(
        ProfileTrafficTotalsCompanion.insert(
          profileId: Value(profileId),
          upload: totalUp,
          download: totalDown,
        ),
      );
      await into(profileTrafficSessions).insertOnConflictUpdate(
        ProfileTrafficSessionsCompanion.insert(
          sessionId: sessionId,
          profileId: profileId,
          upload: nextUp,
          download: nextDown,
        ),
      );
      return true;
    });
  }
}
