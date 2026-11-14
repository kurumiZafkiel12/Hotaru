import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/adapter.dart';
import 'package:hotaru/core/config/profile.dart';
import 'package:hotaru/core/desktop/lifecycle.dart';
import 'package:hotaru/core/desktop/model.dart';
import 'package:hotaru/core/sing_box/config_preparation.dart';
import 'package:hotaru/core/sing_box/desktop_core.dart';
import 'package:hotaru/core/telemetry.dart';
import 'package:hotaru/database/database.dart' as db;
import 'package:hotaru/features/profile_traffic/recorder.dart';
import 'package:hotaru/models/models.dart';
import 'package:mocktail/mocktail.dart';

import '../../core/sing_box/support/telemetry_fixture.dart';

final class _Lifecycle extends Mock implements DesktopCoreLifecycleController {}

final class _Adapter extends Mock implements CoreAdapter, CoreTelemetry {}

final class _Lease implements CoreProcessLease, CoreFinalTrafficSource {
  _Lease(this.sessionId, {this.profileId = 1});
  @override
  final int? profileId;
  final totals = Completer<CoreTrafficTotals?>();
  int stops = 0;
  @override
  final String sessionId;
  @override
  int get pid => 4321;
  @override
  CoreProcessOwner get owner => CoreProcessOwner.helper;
  @override
  Future<CoreTrafficTotals?> get finalTraffic => totals.future;
  @override
  Future<CoreProcessStopResult> stop(Duration timeout) async {
    stops++;
    return const CoreProcessStopResult(stopped: true, exitConfirmed: true);
  }
}

final class _Binding implements SingBoxConfigurationBinding {
  _Binding(this.current, this.adapter);
  @override
  AcceptedSingBoxConfig current;
  final CoreAdapter adapter;
  @override
  CoreAdapter createAdapter() => adapter;
  @override
  Future<CoreLifecycleResult> apply(AcceptedSingBoxConfig configuration) =>
      throw UnimplementedError();
}

Future<AcceptedSingBoxConfig> _configuration(int? id) async {
  final preparation = SingBoxConfigPreparer();
  final result = await preparation.prepare(
    profileId: id,
    import: () async => CoreConfigImportResult(
      profile: CoreProfileSpec(
        nodes: const [
          CoreNodeSpec(tag: 'direct', protocol: CoreNodeProtocol.direct),
        ],
        selectors: [],
        finalOutbound: 'direct',
      ),
      issues: [],
    ),
    listeners: const CoreListenerSpec(
      mixedPort: 17890,
      controllerPort: 19090,
      secret: 'fixture',
    ),
  );
  return preparation.approve(result.candidate!);
}

DesktopCoreRunning _running(_Lease lease) => DesktopCoreRunning(
  DesktopCoreSession(
    sessionId: lease.sessionId,
    lease: lease,
    connectionGeneration: 1,
  ),
);

void main() {
  late db.Database database;
  late _Lifecycle lifecycle;
  late _Adapter adapter;
  late _Binding binding;
  late _Lease lease;
  late DesktopCoreState state;
  late StreamController<DesktopCoreState> events;
  late SingBoxDesktopCore core;
  ProfileTrafficRecorder? recorder;
  final errors = <Object>[];
  var failWrites = false;

  setUp(() async {
    database = db.Database(NativeDatabase.memory());
    await database.profilesDao.setAll([
      Profile.normal().copyWith(id: 1),
      Profile.normal().copyWith(id: 2),
    ]);
    lifecycle = _Lifecycle();
    adapter = _Adapter();
    binding = _Binding(await _configuration(1), adapter);
    lease = _Lease('one');
    state = _running(lease);
    events = StreamController<DesktopCoreState>.broadcast();
    when(() => lifecycle.state).thenAnswer((_) => state);
    when(() => lifecycle.states).thenAnswer((_) => events.stream);
    when(() => adapter.close()).thenAnswer((_) async {});
    when(() => adapter.telemetry()).thenAnswer(
      (_) async => CoreTelemetrySnapshot.fromJson(telemetryFixture()),
    );
    core = SingBoxDesktopCore.withConfiguration(
      lifecycle: lifecycle,
      configuration: binding,
    );
    errors.clear();
    failWrites = false;
    recorder = null;
  });
  tearDown(() async {
    await recorder?.close();
    await core.adapter.close();
    await events.close();
    await database.close();
  });
  ProfileTrafficRecorder start() => recorder = ProfileTrafficRecorder(
    core: core,
    interval: const Duration(days: 1),
    persist: (sample) async {
      if (failWrites) throw StateError('fixture write failure');
      await database.profileTrafficDao.record(
        profileId: sample.profileId,
        sessionId: sample.sessionId,
        upload: sample.upload,
        download: sample.download,
      );
    },
    onError: (error, _) => errors.add(error),
  );

  test(
    'raw totals persist once and final close includes bytes after the last sample',
    () async {
      final current = start();
      await current.sample();
      expect(
        (await database.profileTrafficDao.query(1).getSingle()).upload,
        10,
      );
      state = const DesktopCoreIdle();
      events.add(state);
      lease.totals.complete(const CoreTrafficTotals(upload: 15, download: 35));
      await current.flush();
      await current.flush();
      final total = await database.profileTrafficDao.query(1).getSingle();
      expect(total.upload, 15);
      expect(total.download, 35);
      expect(errors, isEmpty);
      expect(lease.stops, 0);
    },
  );

  test(
    'late final totals retain the committed profile while another profile runs',
    () async {
      final current = start();
      await current.sample();
      binding.current = await _configuration(2);
      state = _running(_Lease('two', profileId: 2));
      events.add(state);
      await pumpEventQueue();
      await current.sample();
      lease.totals.complete(const CoreTrafficTotals(upload: 15, download: 35));
      await current.flush();
      expect(
        (await database.profileTrafficDao.query(1).getSingle()).upload,
        15,
      );
      expect(
        (await database.profileTrafficDao.query(2).getSingle()).upload,
        10,
      );
      expect(errors, isEmpty);
    },
  );

  test(
    'a short running event retains its profile after state already moved on',
    () async {
      state = const DesktopCoreIdle();
      final current = start();
      final shortLease = _Lease('short', profileId: 1);
      events.add(_running(shortLease));
      binding.current = await _configuration(2);
      shortLease.totals.complete(
        const CoreTrafficTotals(upload: 7, download: 9),
      );
      await current.flush();
      expect((await database.profileTrafficDao.query(1).getSingle()).upload, 7);
      expect(
        await database.profileTrafficDao.query(2).getSingleOrNull(),
        isNull,
      );
      verifyNever(() => adapter.telemetry());
    },
  );

  test(
    'a stale live response cannot be credited after configuration replacement',
    () async {
      final current = start();
      await current.sample();
      final pending = Completer<CoreTelemetrySnapshot>();
      when(() => adapter.telemetry()).thenAnswer((_) => pending.future);
      final stale = current.sample();
      binding.current = await _configuration(2);
      state = _running(_Lease('two', profileId: 2));
      events.add(state);
      await pumpEventQueue();
      pending.complete(
        CoreTelemetrySnapshot.fromJson(telemetryFixture(upload: 999999)),
      );
      await stale;
      expect(
        (await database.profileTrafficDao.query(1).getSingle()).upload,
        10,
      );
      expect(
        await database.profileTrafficDao.query(2).getSingleOrNull(),
        isNull,
      );
      expect(errors, isEmpty);
    },
  );

  test(
    'a failed write is reported and a later absolute sample recovers all bytes',
    () async {
      failWrites = true;
      final current = start();
      await current.sample();
      expect(errors, hasLength(1));
      expect(
        await database.profileTrafficDao.query(1).getSingleOrNull(),
        isNull,
      );
      failWrites = false;
      await current.sample();
      expect(
        (await database.profileTrafficDao.query(1).getSingle()).upload,
        10,
      );
    },
  );

  test(
    'idle or unbound configurations do not start a core or query telemetry',
    () async {
      state = const DesktopCoreIdle();
      final current = start();
      await current.sample();
      binding.current = await _configuration(null);
      state = _running(lease);
      events.add(state);
      await pumpEventQueue();
      await current.sample();
      verifyNever(() => adapter.telemetry());
      verifyNever(() => lifecycle.start());
      expect(await database.profileTrafficDao.query().get(), isEmpty);
    },
  );

  test(
    'disposing the recorder leaves process ownership alone and discards late samples',
    () async {
      final current = start();
      await current.sample();
      final pending = Completer<CoreTelemetrySnapshot>();
      when(() => adapter.telemetry()).thenAnswer((_) => pending.future);
      final late = current.sample();
      await current.close();
      pending.complete(
        CoreTelemetrySnapshot.fromJson(telemetryFixture(upload: 999999)),
      );
      await late;
      lease.totals.complete(
        const CoreTrafficTotals(upload: 999999, download: 999999),
      );
      await pumpEventQueue();
      expect(
        (await database.profileTrafficDao.query(1).getSingle()).upload,
        10,
      );
      expect(state, isA<DesktopCoreRunning>());
      expect(lease.stops, 0);
      expect(errors, isEmpty);
    },
  );
}
