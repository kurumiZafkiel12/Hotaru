import 'dart:async';
import 'dart:io';

import 'package:hotaru/common/boot_guard.dart';
import 'package:hotaru/common/core_upgrade.dart';
import 'package:hotaru/core/desktop/core_manifest.dart';
import 'bootstrap_windows.dart';
import 'package:hotaru/common/boot_record.dart';
import 'package:hotaru/common/common.dart';
import 'package:hotaru/common/launch.dart';
import 'package:hotaru/common/migration.dart';
import 'package:hotaru/common/tray.dart';
import 'package:hotaru/common/window.dart';
import 'package:hotaru/database/database.dart';
import 'package:hotaru/l10n/l10n.dart';
import 'package:hotaru/models/models.dart';
import 'package:hotaru/providers/providers.dart';
import 'package:hotaru/state.dart';
import 'package:hotaru/views/navigation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

class Bootstrap {
  static Bootstrap? _instance;

  Bootstrap._internal();

  factory Bootstrap() {
    _instance ??= Bootstrap._internal();
    return _instance!;
  }

  BootDecision _bootDecision = const BootDecision();
  bool _showCoreReimport = false;
  bool _singBoxDesktop = false;

  Future<ProviderContainer> init(int version) async {
    globalState.appEnv = const String.fromEnvironment(
      'APP_ENV',
      defaultValue: 'pre',
    );
    windowPort = window;
    trayPort = appTray;
    navigationPort = navigation;
    final dynamicColor = await _initDynamicColor();
    return _initData(version, dynamicColor);
  }

  Future<DynamicColorSeeds> _initDynamicColor() async {
    return (
      lightSeed: null,
      darkSeed: null,
      accentColor: const Color(defaultPrimaryColor),
    );
  }

  /// Runs before migration and the database: a copy started from another
  /// install path gets past the platform's single-instance hand-off.
  Future<void> _claimDataDirectory() async {
    if (!system.isDesktop || await singleInstanceLock.acquire()) {
      return;
    }
    commonPrint.log('another instance owns the data directory, exiting');
    exit(0);
  }

  Future<ProviderContainer> _initData(
    int version,
    DynamicColorSeeds dynamicColor,
  ) async {
    await _claimDataDirectory();
    globalState.packageInfo = await PackageInfo.fromPlatform();
    var config = await migration.run();
    _bootDecision = await bootGuard.evaluate(
      profileId: config.currentProfileId,
    );
    if (_bootDecision.recovery == BootRecovery.clearProfile) {
      config = config.copyWith(currentProfileId: null);
      await preferences.saveConfig(config);
    }
    final patchClashConfig = config.patchClashConfig.ensureControllerSecret();
    if (patchClashConfig != config.patchClashConfig) {
      config = config.copyWith(patchClashConfig: patchClashConfig);
      await preferences.saveConfig(config);
    }
    final useSingBox =
        Platform.isWindows &&
        !safeModeBuild &&
        await CoreManifest.readSingBoxHostSha256() != null;
    _singBoxDesktop = useSingBox;
    if (useSingBox) {
      final hadSelection = config.currentProfileId != null;
      final upgrade = await DesktopCoreUpgrade(
        readEpoch: preferences.getDesktopCoreEpoch,
        saveEpoch: preferences.setDesktopCoreEpoch,
        saveConfig: preferences.saveConfig,
      ).prepare(config);
      config = upgrade.config;
      _showCoreReimport = upgrade.changed && hadSelection;
    }
    final appState = AppState(
      brightness: WidgetsBinding.instance.platformDispatcher.platformBrightness,
      version: version,
      viewSize: Size.zero,
      requests: FixedList(maxRequestsLength),
      logs: FixedList(maxLogsLength),
      traffics: FixedList(trafficSampleLength),
      totalTraffic: const Traffic(),
      systemUiOverlayStyle: const SystemUiOverlayStyle(),
    );
    final appStateOverrides = buildAppStateOverrides(appState);
    final configOverrides = buildConfigOverrides(config);
    WindowsCoreApplication? windowsApplication;
    ProviderContainer? ownedContainer;
    try {
      if (useSingBox) {
        final directory = await appPath.homeDirPath;
        windowsApplication = await WindowsCoreApplication.create(
          homeDirectory: directory,
          configPath: await appPath.configFilePath,
          mixedPort: config.patchClashConfig.mixedPort,
          providerFiles: _providerFiles,
          review: dialogs.showConfigurationReview,
          persistTraffic: (sample) async {
            await database.profileTrafficDao.record(
              profileId: sample.profileId,
              sessionId: sample.sessionId,
              upload: sample.upload,
              download: sample.download,
            );
          },
          onError: (error, _) => commonPrint.log(
            'Windows background task failed: ${compactError(error)}',
          ),
        );
      }
      final container = ProviderContainer(
        overrides: [
          ...appStateOverrides,
          ...configOverrides,
          if (windowsApplication != null)
            coreHandlerProvider.overrideWithValue(
              windowsApplication.controller,
            ),
        ],
      );
      ownedContainer = container;
      globalState.container = container;
      container
          .read(dynamicColorProvider.notifier)
          .seed(
            lightSeed: dynamicColor.lightSeed,
            darkSeed: dynamicColor.darkSeed,
            accentColor: dynamicColor.accentColor,
          );
      final profiles = await database.profilesDao.query().get();
      container.read(profilesProvider.notifier).reorder(profiles);
      await AppLocalizations.load(
        getLocaleForString(config.appSettingProps.locale) ??
            WidgetsBinding.instance.platformDispatcher.locale,
      );
      await window?.init(version, config.windowProps);
      if (system.isAndroid) {
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      }
      return container;
    } catch (_) {
      try {
        await windowsApplication?.controller.close();
      } finally {
        ownedContainer?.dispose();
      }
      rethrow;
    }
  }

  Future<Map<String, String>> _providerFiles() async {
    final result = <String, String>{};
    final seen = <String>{};
    final rules = await database.clashProvidersDao.query().get();
    final profiles = await database.profilesDao.query().get();
    for (final profile in profiles) {
      final path = await appPath.getProfilePath(profile.id.toString());
      if (await File(path).exists() && seen.add(path)) {
        result['hotaru-files/profile-${profile.id}'] = path;
      }
    }
    for (final rule in rules) {
      for (final (kind, path) in [
        ('source', await rule.path),
        ('compiled', await rule.compiledPath),
      ]) {
        if (await File(path).exists() && seen.add(path)) {
          result['hotaru-files/rule-${rule.id}-$kind'] = path;
        }
      }
    }
    return result;
  }

  Future<void> attach() async {
    if (globalState.isAttach == true) {
      return;
    }
    await _initApp();
    globalState.isAttach = true;
  }

  ProviderContainer get _container => globalState.container;

  Future<void> _initApp() async {
    if (safeModeBuild) {
      unawaited(window?.show());
      _container.read(initProvider.notifier).value = true;
      await bootGuard.markRunning();
      return;
    }
    await latencyDiagnosticsStore.ensureLoaded();
    unawaited(_container.read(systemActionProvider.notifier).updateTray());
    if (!_singBoxDesktop || _container.read(currentProfileIdProvider) != null) {
      unawaited(
        _container.read(profilesActionProvider.notifier).autoUpdateProfiles(),
      );
    }
    unawaited(_container.read(commonActionProvider.notifier).autoCheckUpdate());
    unawaited(
      autoLaunch?.updateStatus(_container.read(appSettingProvider).autoLaunch),
    );
    if (!_container.read(appSettingProvider).silentLaunch) {
      unawaited(window?.show());
    } else {
      unawaited(window?.hide());
    }
    await _handleFailedPreference();
    await _showCrashRecoveryTip();
    await _container.read(coreActionProvider.notifier).startCore();
    if (_showCoreReimport) {
      await dialogs.showAlert(
        title: currentAppLocalizations.singBoxReimportTitle,
        message: TextSpan(text: currentAppLocalizations.singBoxReimportBody),
      );
      _showCoreReimport = false;
    }
    if (!_bootDecision.isDegraded &&
        (!_singBoxDesktop ||
            _container.read(currentProfileIdProvider) != null)) {
      await _container.read(setupActionProvider.notifier).initStatus();
    }
    _container.read(initProvider.notifier).value = true;
    unawaited(_container.read(resourcesActionProvider.notifier).autoUpdate());
    await bootGuard.markRunning();
    unawaited(_container.read(locationPermissionsProvider.notifier).refresh());
  }

  Future<void> _showCrashRecoveryTip() async {
    switch (_bootDecision.recovery) {
      case BootRecovery.none:
        return;
      case BootRecovery.skipAutoSetup:
        await dialogs.showAlert(
          title: currentAppLocalizations.launchInterrupted,
          dismissible: false,
          message: TextSpan(text: currentAppLocalizations.launchInterruptedTip),
        );
      case BootRecovery.clearProfile:
        await dialogs.showAlert(
          title: currentAppLocalizations.crashDetected,
          dismissible: false,
          message: TextSpan(
            text: currentAppLocalizations.crashDetectedTip(_failedProfileLabel),
          ),
        );
    }
  }

  String get _failedProfileLabel {
    final profileId = _bootDecision.failedProfileId;
    if (profileId == null) {
      return '';
    }
    final profile = _container.read(profilesProvider).getProfile(profileId);
    return profile?.label.takeFirstValid(['$profileId']) ?? '$profileId';
  }

  Future<void> _handleFailedPreference() async {
    if (await preferences.isInit) return;
    final res = await dialogs.showMessage(
      title: currentAppLocalizations.tip,
      message: TextSpan(text: currentAppLocalizations.cacheCorrupt),
    );
    if (res == true) {
      final file = File(await appPath.sharedPreferencesPath);
      await file.safeDelete();
    }
    // Saving here would rewrite the preferences file the user just chose to delete.
    await _container.read(systemActionProvider.notifier).handleExit(false);
  }
}

final bootstrap = Bootstrap();
