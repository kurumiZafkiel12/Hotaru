import 'dart:io';

import '../core/mihomo_controller.dart';

class ProxyGuardian {
  String? _token;
  String get executable =>
      '${File(Platform.resolvedExecutable).parent.path}/Hotaru.Guardian.exe';
  Future<void> arm(int corePid, String endpoint) async {
    if (!Platform.isWindows) return;
    if (_token != null) throw StateError('Guardian already armed');
    final token = MihomoController.newSecret().replaceAll(
      RegExp('[^a-zA-Z0-9-]'),
      '',
    );
    final result = await Process.run(executable, [
      'arm',
      token,
      '$pid',
      '$corePid',
      endpoint,
    ]);
    if (result.exitCode != 0) throw StateError('无法启动系统代理崩溃保护，未开启系统代理');
    _token = token;
  }

  Future<void> cancel() async {
    final token = _token;
    if (token == null) return;
    final result = await Process.run(executable, ['cancel', token]);
    if (result.exitCode != 0) throw StateError('等待系统代理保护退出失败');
    _token = null;
  }
}
