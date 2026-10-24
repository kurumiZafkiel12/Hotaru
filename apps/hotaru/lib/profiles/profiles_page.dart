import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';

import '../core/mihomo_controller.dart';
import '../core/proxy_config.dart';
import '../core/core_location.dart';
import '../platform/system_proxy.dart';
import '../storage/atomic_file.dart';
import 'importer.dart';
import 'profile_store.dart';

/// Subscriptions & nodes: import → save → select → run.
///
/// This page owns one [MihomoController]. Leaving the page stops the core;
/// if the system proxy was enabled from here it is restored first.
class ProfilesPage extends StatefulWidget {
  final File? storeFile;
  final MihomoController? controller;
  final SystemProxyAdapter? systemProxyAdapter;
  final bool? systemProxySupported;
  final ValueChanged<String>? onConnectionChanged;

  const ProfilesPage({
    super.key,
    this.storeFile,
    this.controller,
    this.systemProxyAdapter,
    this.systemProxySupported,
    this.onConnectionChanged,
  });

  @override
  State<ProfilesPage> createState() => _ProfilesPageState();
}

class _ProfilesPageState extends State<ProfilesPage> {
  late final MihomoController core = widget.controller ?? MihomoController();
  late final SystemProxyAdapter systemProxy =
      widget.systemProxyAdapter ?? SystemProxyAdapter.forPlatform();
  bool get systemProxySupported =>
      widget.systemProxySupported ?? SystemProxyAdapter.isSupported;

  final content = TextEditingController();
  final url = TextEditingController();
  final name = TextEditingController();
  final exePath = TextEditingController();
  final portField = TextEditingController(text: '7890');

  ProfileStore? store;
  ImportMode mode = ImportMode.nodesOnly;
  bool busy = false;
  bool systemProxyOn = false;
  bool leftoverBackup = false;
  String importMsg = '支持 YAML/JSON、Base64 订阅与节点链接；保存后即可选择节点启动代理。';
  String proxyMsg = '代理未启动。';
  String? delayMsg;
  Directory? runtimeDir;
  AppLifecycleListener? lifecycle;
  Timer? monitor;
  bool proxyChanging = false;
  String? activeProfileId;

  File? get storeFile => widget.storeFile ?? ProfileStore.defaultFile();
  File? get backupFile {
    final f = storeFile;
    return f == null ? null : File('${f.path}.sysproxy.json');
  }

  @override
  void initState() {
    super.initState();
    exePath.text = bundledCorePath();
    lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        if (busy || proxyChanging) return AppExitResponse.cancel;
        try {
          if (systemProxyOn) await _setSystemProxy(false);
          await core.stop();
          if (runtimeDir != null && await runtimeDir!.exists()) {
            await runtimeDir!.delete(recursive: true);
          }
          return AppExitResponse.exit;
        } catch (_) {
          if (mounted) setState(() => proxyMsg = '退出清理失败，请先停止代理并恢复原系统代理后重试。');
          return AppExitResponse.cancel;
        }
      },
    );
    monitor = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (mounted) {
        widget.onConnectionChanged?.call(
          core.status == CoreStatus.running
              ? '运行中 · 127.0.0.1:${core.mixedPort}'
              : core.status == CoreStatus.failed
              ? '内核已退出'
              : '代理未启动',
        );
      }
      if (!mounted ||
          busy ||
          proxyChanging ||
          core.status != CoreStatus.failed) {
        return;
      }
      if (systemProxyOn) {
        try {
          await _setSystemProxy(false);
        } catch (_) {
          if (mounted) setState(() => proxyMsg = '内核已退出，系统代理恢复失败。请使用恢复按钮。');
          return;
        }
      }
      if (mounted) setState(() => proxyMsg = '内核已退出，请检查配置并重新启动。');
    });
    _load();
  }

  Future<void> _load() async {
    final f = storeFile;
    if (f == null) return;
    final loaded = await ProfileStore.load(f);
    final bf = backupFile;
    final hasBackup = bf != null && await bf.exists();
    if (!mounted) return;
    setState(() {
      store = loaded;
      leftoverBackup = hasBackup;
      if (loaded.loadWarning) {
        importMsg = '订阅文件读取失败，已从空白开始；旧文件未被覆盖，直到下一次保存。';
      }
    });
  }

  Future<void> _import(bool remote) async {
    if (core.status == CoreStatus.running) {
      setState(() => importMsg = '导入其他订阅前请先停止代理。');
      return;
    }
    final s = store;
    if (s == null || busy) return;
    setState(() => busy = true);
    try {
      final text = remote
          ? await ProfileImporter.fetch(Uri.parse(url.text.trim()))
          : content.text;
      final parsed = ProfileImporter.parse(text, mode);
      final fallback = remote
          ? (Uri.tryParse(url.text.trim())?.host ?? '订阅')
          : (parsed.config['proxies'] as List).first['name'].toString();
      final saved = await s.add(
        name: name.text.trim().isEmpty ? fallback : name.text.trim(),
        mode: mode,
        source: remote ? 'url' : 'paste',
        config: parsed.config,
      );
      if (mounted) {
        setState(
          () => importMsg =
              '已保存「${saved.name}」：${saved.nodeNames.length} 个节点，已设为当前选择。启动代理后生效。',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() => importMsg = '导入失败：格式、重复名称、端口、参数或大小限制不合要求；已有订阅未受影响。');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _select(StoredProfile profile, String node) async {
    final s = store;
    if (s == null) return;
    if (core.status == CoreStatus.running && activeProfileId != profile.id) {
      setState(() => proxyMsg = '切换订阅前请先停止代理，再选择并重新启动。');
      return;
    }
    try {
      await s.select(profile.id, node);
      if (core.status == CoreStatus.running && core.api != null) {
        final group = await core.api!.selectNode(node);
        if (mounted) {
          setState(
            () => proxyMsg = group != null
                ? '已切换节点：$node（策略组 $group），无需重启。'
                : '已保存选择：$node。当前配置未找到包含该节点的策略组，未强制切换。',
          );
        }
      }
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted) setState(() => proxyMsg = '节点切换或保存失败，请重试。');
    }
  }

  Future<void> _toggleProxy() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      if (core.status == CoreStatus.running) {
        if (systemProxyOn) await _setSystemProxy(false);
        await core.stop();
        if (mounted) setState(() => proxyMsg = '代理已停止。');
      } else {
        final s = store;
        final profile = s?.selectedProfile;
        final node = s?.selectedNode;
        if (profile == null || node == null) {
          setState(() => proxyMsg = '请先导入并选择一个节点。');
          return;
        }
        var port = int.tryParse(portField.text.trim());
        if (port == null || port < 1024 || port > 65535) {
          throw const FormatException('端口必须在 1024–65535');
        }
        // If the requested port is taken, fall back to a free one and say so.
        var note = '';
        try {
          final probe = await ServerSocket.bind(
            InternetAddress.loopbackIPv4,
            port,
          );
          await probe.close();
        } catch (_) {
          port = await MihomoController.findFreePort();
          note = '原端口被占用，已改用 $port。';
        }
        runtimeDir ??= await Directory.systemTemp.createTemp('hotaru-run-');
        final config = ProxyConfigBuilder.build(
          profileConfig: profile.config,
          mode: profile.mode,
          selectedNode: node,
        );
        await core.startRuntime(
          exePath.text.trim(),
          runtimeDir!,
          runtimeConfig: config,
          mixedPort: port,
        );
        activeProfileId = profile.id;
        String? group;
        if (core.api != null) group = await core.api!.selectNode(node);
        if (mounted) {
          setState(
            () => proxyMsg =
                '代理运行中 · Mihomo ${core.coreVersion ?? ''} · 127.0.0.1:$port'
                '（HTTP/SOCKS 混合入口）。$note'
                '${group == null ? '当前配置按自身策略运行。' : '当前节点：$node。'}'
                '未接管系统代理时，需在应用/浏览器里手动设置此代理。',
          );
        }
      }
    } catch (_) {
      if (mounted) {
        setState(() => proxyMsg = core.error ?? '操作失败，请检查内核路径与配置。');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _delay() async {
    final node = store?.selectedNode;
    if (core.api == null || node == null) return;
    setState(() => delayMsg = '正在测速…');
    int? ms;
    try {
      ms = await core.api!.delay(node);
    } catch (_) {
      ms = null;
    }
    if (mounted) {
      setState(
        () => delayMsg = ms == null
            ? '节点「$node」延迟测速失败或超时；不显示估计值。'
            : '节点「$node」延迟：$ms ms（由内核实测）。',
      );
    }
  }

  Future<void> _setSystemProxy(bool on) async {
    if (proxyChanging) throw StateError('System proxy operation in progress');
    proxyChanging = true;
    try {
      final bf = backupFile;
      if (on) {
        if (systemProxyOn) return;
        if (bf == null) throw StateError('Cannot save proxy backup');
        if (await bf.exists()) {
          throw StateError('Restore existing backup before enabling proxy');
        }
        final current = await systemProxy.read();
        await writeTextAtomically(bf, current.encode());
        try {
          await systemProxy.enable('127.0.0.1:${core.mixedPort}');
        } catch (_) {
          try {
            await systemProxy.restore(current);
            await bf.delete();
          } catch (_) {
            if (mounted) setState(() => leftoverBackup = true);
          }
          rethrow;
        }
        if (mounted) {
          setState(() {
            systemProxyOn = true;
            leftoverBackup = false;
            proxyMsg = '系统代理已开启：127.0.0.1:${core.mixedPort}（原设置已备份，关闭时代还原）。';
          });
        }
      } else {
        if (bf != null && await bf.exists()) {
          final saved = SavedProxyState.decode(await bf.readAsString());
          final current = await systemProxy.read();
          if (current.enable == true &&
              current.server == '127.0.0.1:${core.mixedPort}') {
            await systemProxy.restore(saved);
          }
          await bf.delete();
        }
        if (mounted) {
          setState(() {
            systemProxyOn = false;
            proxyMsg = '已释放系统代理；若其他程序修改过设置，保留其最新设置。';
          });
        }
      }
    } finally {
      proxyChanging = false;
    }
  }

  Future<void> _restoreLeftover() async {
    if (busy || proxyChanging) return;
    setState(() => busy = true);
    try {
      final bf = backupFile;
      if (bf == null || !await bf.exists()) return;
      final saved = SavedProxyState.decode(await bf.readAsString());
      await systemProxy.restore(saved);
      await bf.delete();
      if (mounted) {
        setState(() {
          leftoverBackup = false;
          proxyMsg = '已恢复上次遗留的原系统代理设置。';
        });
      }
    } catch (_) {
      if (mounted) setState(() => proxyMsg = '恢复失败，备份已保留，请重试。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    monitor?.cancel();
    lifecycle?.dispose();
    if (systemProxyOn) {
      unawaited(() async {
        try {
          await _setSystemProxy(false);
        } catch (_) {
          // Best effort during teardown; the leftover-backup button on the
          // next launch is the recovery path if this does not complete.
        }
      }());
    }
    unawaited(core.dispose());
    for (final c in [content, url, name, exePath, portField]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = store;
    final running = core.status == CoreStatus.running;
    return Scaffold(
      appBar: AppBar(title: const Text('订阅与节点')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Text(
            '导入 → 保存 → 选节点 → 启动代理。协议：SOCKS5、HTTP(S)、Trojan、SS、VMess、VLESS、Hysteria2；其他参数会明确拒绝，不静默丢弃。',
          ),
          const SizedBox(height: 16),
          DropdownButton<ImportMode>(
            value: mode,
            onChanged: busy ? null : (v) => setState(() => mode = v!),
            items: const [
              DropdownMenuItem(
                value: ImportMode.nodesOnly,
                child: Text('仅导入节点'),
              ),
              DropdownMenuItem(
                value: ImportMode.fullConfig,
                child: Text('完整配置'),
              ),
            ],
          ),
          TextField(
            controller: name,
            enabled: !busy,
            decoration: const InputDecoration(
              labelText: '订阅名称（可空）',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: content,
            minLines: 4,
            maxLines: 8,
            enabled: !busy,
            decoration: const InputDecoration(
              labelText: '粘贴配置、Base64 订阅或节点链接',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: busy || s == null ? null : () => _import(false),
            child: const Text('检查并保存'),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: url,
            enabled: !busy,
            decoration: const InputDecoration(
              labelText: 'HTTPS 订阅地址',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: busy || s == null ? null : () => _import(true),
            child: const Text('下载并保存'),
          ),
          const SizedBox(height: 12),
          Text(importMsg),
          const Divider(height: 40),
          if (s == null)
            const Center(child: CircularProgressIndicator())
          else if (s.profiles.isEmpty)
            const Text('还没有保存的订阅。导入后，节点会列在这里供选择。')
          else
            for (final profile in s.profiles) ...[
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${profile.name} · ${profile.nodeNames.length} 个节点 · '
                      '${profile.mode == ImportMode.fullConfig ? '完整配置' : '仅节点'}',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  IconButton(
                    tooltip: '删除${profile.name}',
                    onPressed: busy || running
                        ? null
                        : () async {
                            await s.remove(profile.id);
                            if (mounted) setState(() {});
                          },
                    icon: const Icon(Icons.delete_outline),
                  ),
                ],
              ),
              for (final node in profile.nodeNames)
                ListTile(
                  dense: true,
                  leading: Icon(
                    s.selectedProfileId == profile.id && s.selectedNode == node
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                  ),
                  title: Text(node),
                  onTap: busy ? null : () => _select(profile, node),
                ),
              const SizedBox(height: 8),
            ],
          const Divider(height: 40),
          const Text('代理控制', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          TextField(
            controller: exePath,
            enabled: !busy && !running,
            decoration: const InputDecoration(
              labelText: 'Mihomo 内核路径（安装版自动填写）',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: portField,
            enabled: !busy && !running,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: '本地混合端口（HTTP/SOCKS）',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: busy || s == null ? null : _toggleProxy,
            child: Text(
              busy
                  ? '正在处理…'
                  : running
                  ? '停止代理'
                  : '启动代理',
            ),
          ),
          const SizedBox(height: 12),
          Text(proxyMsg),
          const SizedBox(height: 12),
          Row(
            children: [
              OutlinedButton(
                onPressed: running ? _delay : null,
                child: const Text('测速当前节点'),
              ),
              const SizedBox(width: 12),
              if (delayMsg != null) Expanded(child: Text(delayMsg!)),
            ],
          ),
          const SizedBox(height: 12),
          if (leftoverBackup && !systemProxyOn)
            OutlinedButton(
              onPressed: systemProxySupported ? _restoreLeftover : null,
              child: const Text('恢复上次遗留的原系统代理设置'),
            ),
          SwitchListTile(
            title: const Text('系统代理（Windows）'),
            subtitle: Text(
              systemProxySupported
                  ? '开启时先备份你原来的代理设置，关闭时原样恢复。需先启动代理。'
                  : '当前平台暂不支持系统代理开关，请手动设置上面的本地代理。',
            ),
            value: systemProxyOn,
            onChanged:
                !systemProxySupported ||
                    !running ||
                    busy ||
                    proxyChanging ||
                    (leftoverBackup && !systemProxyOn)
                ? null
                : (v) async {
                    try {
                      await _setSystemProxy(v);
                    } catch (e) {
                      if (mounted) {
                        setState(() => proxyMsg = '系统代理设置失败：$e');
                      }
                    }
                  },
          ),
        ],
      ),
    );
  }
}
