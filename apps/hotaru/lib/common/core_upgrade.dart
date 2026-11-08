import '../models/models.dart';

const singBoxDesktopEpoch = 'sing-box-v1';

final class DesktopCoreUpgrade {
  final Future<String?> Function() readEpoch;
  final Future<bool> Function(String) saveEpoch;
  final Future<bool> Function(Config) saveConfig;

  const DesktopCoreUpgrade({
    required this.readEpoch,
    required this.saveEpoch,
    required this.saveConfig,
  });

  Future<({Config config, bool changed})> prepare(Config config) async {
    if (await readEpoch() == singBoxDesktopEpoch) {
      return (config: config, changed: false);
    }
    final updated = config.copyWith(
      currentProfileId: null,
      appSettingProps: config.appSettingProps.copyWith(
        routingRulesEnabled: false,
      ),
    );
    if (!await saveConfig(updated)) {
      throw StateError('Cannot persist the desktop core upgrade');
    }
    if (!await saveEpoch(singBoxDesktopEpoch)) {
      throw StateError('Cannot persist the desktop core epoch');
    }
    return (config: updated, changed: true);
  }
}
