import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../core/mihomo_controller.dart';
import '../core/proxy_config.dart';
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

  const ProfilesPage({
    super.key,
    this.storeFile,
    this.controller,
    this.systemProxyAdapter,
    this.systemProxySupported,
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

  File? get storeFile => widget.storeFile ?? ProfileStore.defaultFile();
  File? get backupFile {
    final f = storeFile;
    return f == null ? null : File('${f.path}.sysproxy.json');
  }

  @override
  void initState() {
    super.initState();
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
        var port = int.tryParse(portField.text.trim()) ?? 7890;
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
    final ms = await core.api!.delay(node);
    if (mounted) {
      setState(
        () => delayMsg = ms == null
            ? '节点「$node」延迟测速失败或超时；不显示估计值。'
            : '节点「$node」延迟：$ms ms（由内核实测）。',
      );
    }
  }

  Future<void> _setSystemProxy(bool on) async {
    final bf = backupFile;
    if (on) {
      final current = await systemProxy.read();
      if (bf != null) await writeTextAtomically(bf, current.encode());
      await systemProxy.enable('127.0.0.1:${core.mixedPort}');
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
        await systemProxy.restore(saved);
        await bf.delete();
      }
      if (mounted) {
        setState(() {
          systemProxyOn = false;
          proxyMsg = '系统代理已关闭并恢复原设置。';
        });
      }
    }
  }

  Future<void> _restoreLeftover() async {
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
  }

  @override
  void dispose() {
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
                    onPressed: busy
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
              labelText: '本机 Mihomo 可执行文件绝对路径',
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
            onChanged: !systemProxySupported || !running
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
