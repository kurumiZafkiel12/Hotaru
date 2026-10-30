import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hotaru/common/android_network.dart';
import 'package:hotaru/plugins/app.dart';

final androidNetworkSnapshotProvider =
    FutureProvider.autoDispose<AndroidNetworkSnapshot>(
      (ref) async =>
          await app?.networkSnapshot() ??
          const AndroidNetworkSnapshot(readable: false, reason: 'unavailable'),
    );

final androidNetworkSettingsProvider =
    Provider<Future<bool> Function(AndroidNetworkSetting)>(
      (ref) =>
          (setting) async => await app?.openNetworkSettings(setting) ?? false,
    );
