import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/bootstrap_windows.dart';
import 'package:hotaru/core/adapter.dart';
import 'package:hotaru/core/config/application_settings.dart';
import 'package:hotaru/core/desktop/lifecycle.dart';
import 'package:hotaru/core/desktop/model.dart';
import 'package:hotaru/core/routing_mode.dart';
import 'package:hotaru/core/sing_box/config_preparation.dart';
import 'package:hotaru/core/sing_box/desktop_core.dart';
import 'package:hotaru/core/telemetry.dart';
import 'package:hotaru/features/profile_traffic/recorder.dart';
import 'package:hotaru/models/models.dart' show SetupParams;
import 'package:mocktail/mocktail.dart';

import 'core/sing_box/support/telemetry_fixture.dart';

class _Lifecycle extends Mock implements DesktopCoreLifecycleController {}

class _Adapter extends Mock
    implements CoreAdapter, CoreRoutingModes, CoreTelemetry {}

class _Lease implements CoreProcessLease, CoreFinalTrafficSource {
  _Lease(this.sessionId, this.profileId);
  @override
  final String sessionId;
  @override
  final int? profileId;
  final totals = Completer<CoreTrafficTotals?>();
  @override
  Future<CoreTrafficTotals?> get finalTraffic => totals.future;
  @override
  int get pid => 4321;
  @override
  CoreProcessOwner get owner => CoreProcessOwner.helper;
  @override
  Future<CoreProcessStopResult> stop(Duration timeout) async =>
      const CoreProcessStopResult(stopped: true, exitConfirmed: true);
}

class _Binding implements SingBoxConfigurationBinding {
  _Binding(this.current, this.adapter, this.applyConfiguration);
  @override
  AcceptedSingBoxConfig current;
  final CoreAdapter adapter;
  final Future<CoreLifecycleResult> Function(AcceptedSingBoxConfig)
  applyConfiguration;
  @override
  CoreAdapter createAdapter() => adapter;
  @override
  Future<CoreLifecycleResult> apply(AcceptedSingBoxConfig configuration) =>
      applyConfiguration(configuration);
}

void main() {
  test(
    'application assembly starts control-only, imports explicitly and persists final bytes before close completes',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'hotaru-windows-assembly-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final config = await File(
        '${directory.path}/config.yaml',
      ).writeAsString('old config must not auto-activate');
      final lifecycle = _Lifecycle();
      final adapter = _Adapter();
      final events = StreamController<DesktopCoreState>.broadcast();
      final crashes = StreamController<DesktopCoreFailure>.broadcast();
      addTearDown(events.close);
      addTearDown(crashes.close);
      DesktopCoreState state = const DesktopCoreIdle();
      _Lease? lease;
      late _Binding binding;
      var generation = 0;
      final persisted = <ProfileTrafficObservation>[];
      final errors = <Object>[];
      Future<CoreLifecycleResult> running(
        AcceptedSingBoxConfig configuration,
      ) async {
        if (lease case final previous?) {
          if (!previous.totals.isCompleted) {
            previous.totals.complete(
              const CoreTrafficTotals(upload: 1, download: 2),
            );
          }
        }
        binding.current = configuration;
        lease = _Lease('session-${++generation}', configuration.profileId);
        state = DesktopCoreRunning(
          DesktopCoreSession(
            sessionId: lease!.sessionId,
            lease: lease!,
            connectionGeneration: generation,
          ),
        );
        events.add(state);
        return CoreLifecycleResult(
          revision: generation,
          outcome: CoreLifecycleOutcome.applied,
          session: (state as DesktopCoreRunning).session,
        );
      }

      when(() => lifecycle.state).thenAnswer((_) => state);
      when(() => lifecycle.states).thenAnswer((_) => events.stream);
      when(() => lifecycle.crashEvents).thenAnswer((_) => crashes.stream);
      when(() => lifecycle.start()).thenAnswer((_) => running(binding.current));
      when(() => lifecycle.close()).thenAnswer((_) async {
        if (lease case final previous?) {
          if (!previous.totals.isCompleted) {
            previous.totals.complete(
              const CoreTrafficTotals(upload: 101, download: 202),
            );
          }
        }
        state = const DesktopCoreClosed(9);
        events.add(state);
        return const CoreLifecycleResult(
          revision: 9,
          outcome: CoreLifecycleOutcome.applied,
        );
      });
      when(() => adapter.close()).thenAnswer((_) async {});
      when(
        () => adapter.routingMode(),
      ).thenAnswer((_) async => CoreRoutingMode.rule);
      when(() => adapter.outbounds()).thenAnswer((_) async => []);
      when(() => adapter.telemetry()).thenAnswer(
        (_) async => CoreTelemetrySnapshot.fromJson(telemetryFixture()),
      );
      final application = await WindowsCoreApplication.create(
        homeDirectory: directory.path,
        configPath: config.path,
        mixedPort: 17890,
        providerFiles: () async => {},
        resolveGeo: (_) async => {},
        review: (_) async => true,
        persistTraffic: (sample) async {
          persisted.add(sample);
        },
        onError: (error, _) => errors.add(error),
        onEvent: (_) {},
        createCore: (configuration) async {
          binding = _Binding(configuration, adapter, running);
          return SingBoxDesktopCore.withConfiguration(
            lifecycle: lifecycle,
            configuration: binding,
          );
        },
      );
      addTearDown(application.controller.close);
      final initial = application.core.configuration!;
      expect(initial.profileId, isNull);
      expect(
        (initial.applicationData as CoreApplicationSettings).unconfigured,
        isTrue,
      );
      expect(initial.listeners.inboundsEnabled, isFalse);
      expect(initial.listeners.activeTun, isNull);
      expect(initial.listeners.secret, isNot(initial.listeners.probe!.secret));
      expect(await config.readAsString(), 'old config must not auto-activate');
      verifyNever(() => lifecycle.start());
      await application.controller.start();
      expect((await application.controller.getProxies()).proxies, isEmpty);
      await config.writeAsString('''
proxies: [{name: A, type: http, server: 127.0.0.1, port: 18080}]
proxy-groups: [{name: selected, type: select, proxies: [A]}]
rules: ["MATCH,selected"]
ipv6: true
''');
      expect(
        await application.controller.setupConfig(
          params: const SetupParams(
            selectedMap: {},
            testUrl: 'https://fixture.invalid',
          ),
          profileId: 7,
        ),
        '',
      );
      expect(application.core.configuration!.profileId, 7);
      expect(
        (application.core.configuration!.applicationData
                as CoreApplicationSettings)
            .unconfigured,
        isFalse,
      );
      expect(
        application.core.configuration!.listeners.inboundsEnabled,
        isFalse,
      );
      await Future<void>.delayed(Duration.zero);
      await application.controller.close();
      expect(persisted, isNotEmpty);
      expect(
        (
          persisted.last.profileId,
          persisted.last.upload,
          persisted.last.download,
        ),
        (7, 101, 202),
      );
      expect(errors, isEmpty);
      await application.controller.close();
      verify(() => lifecycle.close()).called(1);
    },
  );
}
