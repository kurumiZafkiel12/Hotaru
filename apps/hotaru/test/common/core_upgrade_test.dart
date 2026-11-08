import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/common/core_upgrade.dart';
import 'package:hotaru/models/models.dart';

void main() {
  Config original() => Config(
    themeProps: defaultThemeProps,
    currentProfileId: 7,
    appSettingProps: const AppSettingProps(
      autoRun: true,
      routingRulesEnabled: true,
    ),
    patchClashConfig: defaultClashConfig.copyWith.tun(enable: true),
  );

  test(
    'first engine upgrade clears activation intent and commits the epoch after settings',
    () async {
      final order = <String>[];
      Config? saved;
      final before = original();
      final migration = DesktopCoreUpgrade(
        readEpoch: () async => null,
        saveConfig: (config) async {
          order.add('config');
          saved = config;
          return true;
        },
        saveEpoch: (epoch) async {
          order.add(epoch);
          return true;
        },
      );
      final result = await migration.prepare(before);
      expect(result.changed, isTrue);
      expect(order, ['config', singBoxDesktopEpoch]);
      expect(saved, result.config);
      expect(result.config.currentProfileId, isNull);
      expect(
        result.config.appSettingProps.autoRun,
        before.appSettingProps.autoRun,
      );
      expect(result.config.appSettingProps.routingRulesEnabled, isFalse);
      expect(result.config.patchClashConfig, before.patchClashConfig);
      expect(result.config.networkProps, before.networkProps);
      expect(result.config.themeProps, before.themeProps);
      expect(
        result.config.patchClashConfig.mixedPort,
        before.patchClashConfig.mixedPort,
      );
      expect(before.currentProfileId, 7);
    },
  );

  test(
    'a completed engine upgrade does not reset later explicit choices',
    () async {
      final before = original();
      final result = await DesktopCoreUpgrade(
        readEpoch: () async => singBoxDesktopEpoch,
        saveConfig: (_) async => throw StateError('Must not save'),
        saveEpoch: (_) async => throw StateError('Must not save'),
      ).prepare(before);
      expect(result.changed, isFalse);
      expect(identical(result.config, before), isTrue);
    },
  );

  test(
    'failed settings persistence never marks the upgrade complete',
    () async {
      var marked = false;
      await expectLater(
        DesktopCoreUpgrade(
          readEpoch: () async => null,
          saveConfig: (_) async => false,
          saveEpoch: (_) async {
            marked = true;
            return true;
          },
        ).prepare(original()),
        throwsStateError,
      );
      expect(marked, isFalse);
    },
  );

  test(
    'failed epoch persistence remains retryable without restoring old activation',
    () async {
      final saved = <Config>[];
      final migration = DesktopCoreUpgrade(
        readEpoch: () async => null,
        saveConfig: (config) async {
          saved.add(config);
          return true;
        },
        saveEpoch: (_) async => false,
      );
      await expectLater(migration.prepare(original()), throwsStateError);
      expect(saved.single.currentProfileId, isNull);
      await expectLater(migration.prepare(saved.single), throwsStateError);
      expect(saved.last.currentProfileId, isNull);
    },
  );
}
