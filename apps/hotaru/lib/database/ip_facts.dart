part of 'database.dart';

@DataClassName('IpFactsRecord')
class IpFactRecords extends Table {
  TextColumn get ip => text()();
  TextColumn get facts => text().map(const IpFactsConverter())();
  DateTimeColumn get checkedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {ip};
}

@DriftAccessor(tables: [IpFactRecords])
class IpFactsDao extends DatabaseAccessor<Database> with _$IpFactsDaoMixin {
  IpFactsDao(super.attachedDatabase);

  Future<IpFactsRecord?> cached(String ip) =>
      (select(ipFactRecords)..where((t) => t.ip.equals(ip))).getSingleOrNull();

  Future<void> put(IpFacts facts) => transaction(() async {
    await (delete(ipFactRecords)..where(
          (t) => t.checkedAt.isSmallerThanValue(
            DateTime.now().subtract(const Duration(days: 2)),
          ),
        ))
        .go();
    await into(ipFactRecords).insertOnConflictUpdate(
      IpFactRecordsCompanion.insert(
        ip: facts.ip,
        facts: facts,
        checkedAt: facts.checkedAt,
      ),
    );
    await customStatement(
      'DELETE FROM ip_fact_records WHERE ip NOT IN (SELECT ip FROM ip_fact_records ORDER BY checked_at DESC LIMIT 512)',
    );
  });
}
