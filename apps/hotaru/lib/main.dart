import 'dart:io';
import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show LicenseRegistry, LicenseEntryWithLineBreaks;
import 'package:flutter/services.dart' show rootBundle;

import 'core/mihomo_controller.dart';
import 'profiles/import_page.dart';
import 'dashboard.dart';

void main() {
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'Hotaru (GPL-3.0-or-later)',
      'Mihomo (GPL-3.0)',
    ], await rootBundle.loadString('assets/LICENSE.txt'));
  });
  runApp(const HotaruApp());
}

class HotaruApp extends StatelessWidget {
  const HotaruApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Hotaru · 蛍',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      // Hotaru palette, kept deliberately small: deep slate surfaces,
      // firefly green reserved for primary actions and selection states.
      colorScheme: const ColorScheme.dark(
        primary: Color(0xffc7e9a3),
        onPrimary: Color(0xff16211a),
        surface: Color(0xff111a1c),
        surfaceContainer: Color(0xff1c2a2e),
        surfaceContainerHighest: Color(0xff24373c),
        outline: Color(0xff394a41),
      ),
      scaffoldBackgroundColor: const Color(0xff111a1c),
      cardTheme: const CardThemeData(
        color: Color(0xff1c2a2e),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(20)),
        ),
      ),
      useMaterial3: true,
    ),
    home: const Dashboard(diagnostic: CorePage()),
  );
}

class CorePage extends StatefulWidget {
  const CorePage({super.key});
  @override
  State<CorePage> createState() => _CorePageState();
}

class _CorePageState extends State<CorePage> {
  final core = MihomoController();
  final path = TextEditingController();
  bool busy = false;
  String message = '桌面内核诊断：不启用系统代理、不启用 TUN。';
  Directory? runtime;
  late final AppLifecycleListener lifecycle;
  Timer? monitor;

  @override
  void initState() {
    super.initState();
    monitor = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && !busy && core.status == CoreStatus.failed) {
        setState(() => message = core.error ?? '内核已异常退出');
      }
    });
    lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        if (busy) return AppExitResponse.cancel;
        await core.dispose();
        if (runtime != null && await runtime!.exists()) {
          await runtime!.delete(recursive: true);
        }
        return AppExitResponse.exit;
      },
    );
  }

  Future<void> toggle() async {
    setState(() => busy = true);
    try {
      if (core.status == CoreStatus.running) {
        await core.stop();
        message = '内核已停止';
      } else {
        runtime ??= await Directory.systemTemp.createTemp('hotaru-');
        // No fixed control port: pick a free loopback port per launch so a
        // stale process or another app on 19090 cannot block diagnostics.
        final port = await MihomoController.findFreePort();
        await core.startDiagnostic(path.text.trim(), runtime!, port);
        message = '内核健康检查通过。当前未开启代理入口，不代表已经代理网络流量。';
      }
    } catch (_) {
      message = core.error ?? '启动失败，请检查内核路径。';
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  void dispose() {
    monitor?.cancel();
    lifecycle.dispose();
    path.dispose();
    // Leaving this page (not only exiting the app) must stop the core this
    // page started; previously the child process was leaked on navigation.
    // MihomoController.dispose never throws and is safe while busy.
    unawaited(core.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('✦ Hotaru · 蛍'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: (_) => const ImportPage())),
          child: const Text('导入预览'),
        ),
      ],
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.all(32),
          children: [
            Text(
              '一点微光，自在连接。',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 12),
            const Text('开发预览 · Mihomo 桌面适配层'),
            const SizedBox(height: 32),
            TextField(
              controller: path,
              decoration: const InputDecoration(
                labelText: '本机 Mihomo 可执行文件绝对路径',
                border: OutlineInputBorder(),
              ),
              enabled: !busy && core.status != CoreStatus.running,
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: busy || Platform.isAndroid ? null : toggle,
              child: Text(
                busy
                    ? '正在检查…'
                    : core.status == CoreStatus.running
                    ? '停止内核'
                    : '验证并启动诊断内核',
              ),
            ),
            const SizedBox(height: 24),
            Text(message),
            const SizedBox(height: 24),
            const Text(
              '正常退出时停止本应用启动的内核。强制终止应用的清理保障、订阅导入和系统网络管理尚待实现。Android VPN 服务尚未实现。',
            ),
          ],
        ),
      ),
    ),
  );
}
