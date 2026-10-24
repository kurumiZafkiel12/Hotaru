import 'dart:io';

import 'package:flutter/services.dart';

class DesktopIntegration {
  static const channel = MethodChannel('hotaru/desktop');
  static Future<void> status(bool running) async {
    if (!Platform.isWindows) return;
    try {
      await channel.invokeMethod<void>('status', running);
    } on MissingPluginException {
      /* Widget tests. */
    }
  }

  static Future<void> exit() => channel.invokeMethod<void>('exit');
  static Future<bool> autostartEnabled() async {
    if (!Platform.isWindows) return false;
    final result = await Process.run('reg.exe', [
      'query',
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run',
      '/v',
      'Hotaru',
    ]);
    return result.exitCode == 0;
  }

  static Future<void> autostart(bool enabled) async {
    final result = await Process.run(
      'reg.exe',
      enabled
          ? [
              'add',
              r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run',
              '/v',
              'Hotaru',
              '/t',
              'REG_SZ',
              '/d',
              '"${Platform.resolvedExecutable}" --silent',
              '/f',
            ]
          : [
              'delete',
              r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run',
              '/v',
              'Hotaru',
              '/f',
            ],
    );
    if (result.exitCode != 0 && enabled) throw StateError('开机自启保存失败');
  }
}
