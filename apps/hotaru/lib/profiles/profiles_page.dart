import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/mihomo_controller.dart';
import '../core/proxy_config.dart';
import '../core/core_location.dart';
import '../platform/system_proxy.dart';
import '../storage/atomic_file.dart';
import 'aggregate.dart';
import 'importer.dart';
import 'profile_store.dart';
import 'overrides.dart';
import '../platform/proxy_guardian.dart';
import '../platform/desktop.dart';
import '../platform/app_updater.dart';

/// Subscriptions & nodes: import → save → select → run.
///
/// This page owns one [MihomoController]. Leaving the page stops the core;
/// if the system proxy was enabled from here it is restored first.
class ProfilesPage extends StatefulWidget {
  final String panel;
  final File? storeFile;
  final MihomoController? controller;
  final SystemProxyAdapter? systemProxyAdapter;
  final bool? systemProxySupported;
  final ValueChanged<String>? onConnectionChanged;
  final ValueChanged<Map<String, String>>? onMetricsChanged;

  const ProfilesPage({
    super.key,
    this.panel = 'all',
    this.storeFile,
    this.controller,
    this.systemProxyAdapter,
    this.systemProxySupported,
    this.onConnectionChanged,
    this.onMetricsChanged,
  });

  @override
  State<ProfilesPage> createState() => _ProfilesPageState();
}

class _ProfilesPageState extends State<ProfilesPage> {
  bool get desktopEnabled =>
      !Platform.environment.containsKey('FLUTTER_TEST') &&
      widget.storeFile == null;
  late final MihomoController core = widget.controller ?? MihomoController();
  late final SystemProxyAdapter systemProxy =
      widget.systemProxyAdapter ?? SystemProxyAdapter.forPlatform();
  bool get systemProxySupported =>
      widget.systemProxySupported ?? SystemProxyAdapter.isSupported;

  final content = TextEditingController();
  final url = TextEditingController();
  final name = TextEditingController();
  final exePath = TextEditingController();
  final aggregateUrls = TextEditingController();
  final filePath = TextEditingController();
  final portField = TextEditingController(text: '7890');

  final guardian = ProxyGuardian();
  ProfileStore? store;
  Timer? subscriptionTimer;
  Timer? updateTimer;
  AppUpdate? availableUpdate;
  String updateMessage = '启动后自动检查更新；安装前会校验 SHA256。';
  bool updating = false;
  Map<String, dynamic> liveProxies = {};
  Map<String, dynamic> providers = {};
  Map<String, dynamic> ruleProviders = {};
  List<dynamic> connections = [];
  final logs = <String>[];
  StreamSubscription<Map<String, dynamic>>? logStream;
  StreamSubscription<Map<String, dynamic>>? trafficStream;
  final latency = <String, int?>{};
  final tcpLatency = <String, int?>{};
  bool sorting = false;
  bool testing = false;
  bool polling = false;
  bool autostart = false;
  bool serviceReady = false;
  bool serviceInstalled = false;
  bool useService = false;
  String routing = 'rule';
  int upload = 0, download = 0;
  String nodeFilter = '';
  String? chosenGroup;

  ImportMode mode = ImportMode.fullConfig;
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
        final profile = store?.selectedProfile;
        final current = liveProxies[chosenGroup] ?? liveProxies['HOTARU'];
        widget.onMetricsChanged?.call({
          'traffic': core.api == null
              ? '— KB/s'
              : '↑ ${(upload / 1024).toStringAsFixed(1)} / ↓ ${(download / 1024).toStringAsFixed(1)} KB/s',
          'node': current is Map && current['now'] is String
              ? current['now'] as String
              : (store?.selectedNode ?? '在节点页选择'),
          'quota': profile == null
              ? '尚未导入订阅'
              : _profileSummary(profile).split('\n').first,
        });
      }
      if (mounted && core.api != null && !polling) unawaited(_refreshLive());
      if (desktopEnabled) {
        unawaited(DesktopIntegration.status(core.status == CoreStatus.running));
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
    if (Platform.isWindows &&
        widget.systemProxyAdapter == null &&
        desktopEnabled) {
      DesktopIntegration.channel.setMethodCallHandler((call) async {
        if (call.method == 'exitRequested') await _exit();
      });
      DesktopIntegration.autostartEnabled().then((v) {
        if (mounted) setState(() => autostart = v);
      });
      unawaited(_serviceStatus());
    }
    subscriptionTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => _scheduledUpdates(),
    );
    if (Platform.isWindows && desktopEnabled) {
      unawaited(_checkUpdate());
      updateTimer = Timer.periodic(
        const Duration(hours: 6),
        (_) => _checkUpdate(),
      );
    }
    _load();
  }

  Future<void> _action(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      if (mounted) setState(() => proxyMsg = '操作失败，原配置已保留；请检查网络或配置格式。');
    }
  }

  Future<void> _checkUpdate() async {
    try {
      final update = await AppUpdater.check(
        proxyPort: core.api == null ? null : core.mixedPort,
      );
      if (mounted) {
        setState(() {
          availableUpdate = update;
          updateMessage = update == null
              ? '当前已是最新可用版本。'
              : '发现更新 ${update.tag}，可下载并覆盖安装，保留订阅与设置。';
        });
      }
    } catch (_) {
      if (mounted) setState(() => updateMessage = '更新检查失败，可稍后重试。');
    }
  }

  Future<void> _serviceStatus() async {
    try {
      final result = await Process.run(
        '${File(Platform.resolvedExecutable).parent.path}/Hotaru.Service.exe',
        ['status'],
      );
      var preferred = true;
      final prefs = File('${storeFile!.parent.path}/preferences-v1.json');
      if (await prefs.exists()) {
        try {
          preferred =
              (jsonDecode(await prefs.readAsString()) as Map)['useService'] !=
              false;
        } catch (_) {
          preferred = false;
        }
      }
      if (mounted) {
        setState(() {
          serviceReady = result.exitCode == 0;
          serviceInstalled = result.exitCode == 0 || result.exitCode == 4;
          useService = serviceReady && preferred;
        });
      }
    } catch (_) {
      /* Optional service may be absent in development. */
    }
  }

  Future<void> _manageService(bool install) async {
    if (busy || core.status == CoreStatus.running) return;
    setState(() => busy = true);
    await _action(() async {
      await DesktopIntegration.channel.invokeMethod<void>(
        install ? 'installService' : 'removeService',
      );
      await Future<void>.delayed(const Duration(seconds: 1));
      await _serviceStatus();
    });
    if (mounted) setState(() => busy = false);
  }

  Future<void> _preferService(bool value) async {
    if (busy) return;
    setState(() => busy = true);
    await _action(() async {
      await writeJsonAtomically(
        File('${storeFile!.parent.path}/preferences-v1.json'),
        {'useService': value},
      );
      if (mounted) setState(() => useService = value);
    });
    if (mounted) setState(() => busy = false);
  }

  Future<void> _installUpdate() async {
    final update = availableUpdate;
    if (update == null || updating || busy) return;
    setState(() {
      updating = true;
      updateMessage = '正在下载并验证安装包…';
    });
    try {
      final file = await AppUpdater.download(
        update,
        proxyPort: core.api == null ? null : core.mixedPort,
      );
      if (systemProxyOn) await _setSystemProxy(false);
      await core.stop();
      final result = await Process.run(guardian.executable, [
        'update',
        '$pid',
        file.path,
      ]);
      if (result.exitCode != 0) throw StateError('更新程序启动失败');
      await DesktopIntegration.exit();
    } catch (_) {
      if (mounted) {
        setState(() => updateMessage = '更新失败，当前版本保留。网络或校验失败时不会执行安装。');
      }
    } finally {
      if (mounted) setState(() => updating = false);
    }
  }

  Future<void> _exit() async {
    if (busy || proxyChanging) return;
    await _action(() async {
      if (systemProxyOn) await _setSystemProxy(false);
      await core.stop();
      await DesktopIntegration.exit();
    });
  }

  void _startStreams() {
    unawaited(logStream?.cancel());
    unawaited(trafficStream?.cancel());
    final api = core.api;
    if (api == null) return;
    logStream = api.events('/logs?level=info').listen((event) {
      if (!mounted) return;
      setState(() {
        logs.add('${event['type'] ?? ''} ${event['payload'] ?? ''}');
        if (logs.length > 200) logs.removeAt(0);
      });
    }, onError: (Object _) {});
    trafficStream = api.events('/traffic').listen((event) {
      if (mounted) {
        setState(() {
          upload = event['up'] as int? ?? 0;
          download = event['down'] as int? ?? 0;
        });
      }
    }, onError: (Object _) {});
  }

  Future<void> _refreshLive() async {
    final api = core.api;
    if (api == null || polling) return;
    polling = true;
    try {
      final values = await Future.wait([
        api.proxies(),
        api.getMap('/providers/proxies'),
        api.getMap('/providers/rules'),
        api.connections(),
        api.getMap('/configs'),
      ]);
      if (!mounted || core.api != api) return;
      setState(() {
        liveProxies = values[0];
        providers = (values[1]['providers'] as Map? ?? {})
            .cast<String, dynamic>();
        // Include every provider node even when no group currently references it.
        for (final p in providers.values) {
          if (p is Map && p['proxies'] is List) {
            for (final node in p['proxies'] as List) {
              if (node is Map && node['name'] is String) {
                liveProxies[node['name'] as String] = node;
              }
            }
          }
        }
        ruleProviders = (values[2]['providers'] as Map? ?? {})
            .cast<String, dynamic>();
        if (chosenGroup != '*' &&
            (chosenGroup == null || !liveProxies.containsKey(chosenGroup))) {
          chosenGroup = liveProxies.entries
              .where(
                (e) =>
                    e.key != 'GLOBAL' &&
                    e.value is Map &&
                    e.value['all'] is List,
              )
              .firstOrNull
              ?.key;
        }
        connections = values[3]['connections'] as List? ?? [];
        routing = values[4]['mode'] as String? ?? 'rule';
      });
    } catch (_) {
      /* Keep last snapshot on transient API failures. */
    } finally {
      polling = false;
    }
  }

  String _profileSummary(StoredProfile profile) {
    final fields = <String, int>{};
    for (final field in (profile.userInfo ?? '').split(';')) {
      final pair = field.trim().split('=');
      final value = pair.length == 2 ? num.tryParse(pair[1].trim()) : null;
      if (value != null &&
          value.isFinite &&
          value >= 0 &&
          value <= 0x7fffffffffffffff) {
        fields[pair[0].trim().toLowerCase()] = value.toInt();
      }
    }
    final total = fields['total'];
    final remaining = total == null
        ? null
        : (total - (fields['upload'] ?? 0) - (fields['download'] ?? 0)).clamp(
            0,
            total,
          );
    final expiry = fields['expire'];
    final expire = expiry != null && expiry <= 8640000000000 ? expiry : null;
    return '${remaining == null ? '流量：来源未提供' : '剩余 ${(remaining / 1073741824).toStringAsFixed(2)} GB / ${(total! / 1073741824).toStringAsFixed(2)} GB'}'
        ' · ${expire == null || expire <= 0 ? '到期：来源未提供' : '到期：${DateTime.fromMillisecondsSinceEpoch(expire * 1000).toLocal().toString().split(' ').first}'}'
        '\n${profile.updatedAt == null ? '尚未更新' : '更新于 ${profile.updatedAt!.toLocal()}'} · ${profile.sourceUrl == null
            ? (profile.source == 'url' ? '旧版未保存原链接，重新导入可启用更新' : '本地配置，手动维护')
            : profile.updateHours == 0
            ? '手动更新'
            : '每 ${profile.updateHours} 小时更新'}';
  }

  Future<void> _scheduledUpdates() async {
    if (!mounted || busy || store == null) return;
    for (final profile in List<StoredProfile>.of(store!.profiles)) {
      if (profile.sourceUrl == null || profile.updateHours == 0) continue;
      if (DateTime.now()
              .difference(profile.updatedAt ?? profile.createdAt)
              .inHours >=
          profile.updateHours) {
        await _updateProfile(profile);
      }
    }
  }

  Future<void> _updateProfile(StoredProfile profile) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final response = await ProfileImporter.fetchSubscription(
        Uri.parse(profile.sourceUrl!),
        proxyPort: core.api == null ? null : core.mixedPort,
      );
      final parsed = ProfileImporter.parse(response.body, profile.mode);
      final next = StoredProfile.fromJson({
        ...profile.toJson(),
        'config': parsed.config,
        'userInfo': response.userInfo,
        'updatedAt': DateTime.now().toIso8601String(),
      });
      // Validate the result after user overrides before replacing the saved source.
      final candidate = await ProfileOverrides.buildRuntime(
        source: next.config,
        mode: next.mode,
        selectedNode: next.nodeNames.contains(store!.selectedNode)
            ? store!.selectedNode!
            : (next.nodeNames.firstOrNull ?? ''),
        overlay: next.merge,
        script: next.script,
      );
      await _validateRuntime(candidate);
      await store!.replace(next);
      if (mounted) {
        setState(
          () => importMsg =
              '「${profile.name}」已更新；覆写已保留。${activeProfileId == profile.id ? '当前连接继续使用原配置，停止再启动后应用更新。' : ''}',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() => importMsg = '「${profile.name}」更新失败，旧订阅及覆写完整保留。');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _editOverrides(StoredProfile profile) async {
    if (busy) return;
    setState(() => busy = true);
    final merge = TextEditingController(
      text: const JsonEncoder.withIndent('  ').convert(profile.merge),
    );
    final script = TextEditingController(text: profile.script);
    final interval = TextEditingController(text: '${profile.updateHours}');
    String? error;
    var saving = false;
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => StatefulBuilder(
          builder: (context, update) => PopScope(
            canPop: !saving,
            child: AlertDialog(
              title: Text('${profile.name} · 覆写'),
              content: SizedBox(
                width: 700,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        '顺序：原订阅 → Merge → Script。字典递归合并，数组整体替换。仅运行你信任并主动填写的脚本；保存不会立即改变当前连接。',
                      ),
                      TextField(
                        controller: interval,
                        enabled: !saving,
                        decoration: const InputDecoration(
                          labelText: '更新间隔（小时，0 为关闭，最大 720）',
                        ),
                      ),
                      TextField(
                        controller: merge,
                        enabled: !saving,
                        minLines: 4,
                        maxLines: 8,
                        decoration: const InputDecoration(
                          labelText: 'Merge · YAML/JSON',
                        ),
                      ),
                      TextField(
                        controller: script,
                        enabled: !saving,
                        minLines: 4,
                        maxLines: 8,
                        decoration: const InputDecoration(
                          labelText: 'Script · function main(config) { return config; }',
                        ),
                      ),
                      if (error != null) Text(error!),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: saving ? null : () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: saving
                      ? null
                      : () async {
                          update(() => saving = true);
                          try {
                            final hours = int.parse(interval.text);
                            if (hours < 0 || hours > 720) {
                              throw const FormatException();
                            }
                            final overlay = ProfileOverrides.parseMerge(
                              merge.text,
                            );
                            final scriptValue = script.text;
                            final transformed =
                                await ProfileOverrides.buildRuntime(
                                  source: profile.config,
                                  mode: profile.mode,
                                  selectedNode:
                                      profile.nodeNames.firstOrNull ?? '',
                                  overlay: overlay,
                                  script: scriptValue,
                                );
                            await _validateRuntime(transformed);
                            await store!.replace(
                              StoredProfile.fromJson({
                                ...profile.toJson(),
                                'merge': overlay,
                                'script': scriptValue,
                                'updateHours': hours,
                              }),
                            );
                            if (context.mounted) {
                              update(() => saving = false);
                              Navigator.pop(context);
                            }
                            if (mounted) setState(() {});
                          } catch (_) {
                            if (context.mounted) {
                              update(
                                () => error =
                                    '保存失败：检查 Merge、Script、内核配置和更新间隔；旧设置未改动。',
                              );
                            }
                          } finally {
                            if (context.mounted) update(() => saving = false);
                          }
                        },
                  child: const Text('检查并保存'),
                ),
              ],
            ),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => busy = false);
    }
    // Dialog animation may still reference its controllers after completion.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    merge.dispose();
    script.dispose();
    interval.dispose();
  }

  Future<void> _testNodes(List<String> names, {bool tcp = false}) async {
    if (testing) return;
    setState(() => testing = true);
    final api = core.api;
    final profile = store?.selectedProfile;
    var index = 0;
    Future<void> worker() async {
      while (index < names.length && mounted && core.api == api) {
        final name = names[index++];
        int? ms;
        if (tcp) {
          final node = profile?.nodes
              .where((n) => n['name'] == name)
              .firstOrNull;
          if (node?['server'] is String && node?['port'] is int) {
            final watch = Stopwatch()..start();
            try {
              final socket = await Socket.connect(
                node!['server'] as String,
                node['port'] as int,
                timeout: const Duration(seconds: 3),
              );
              ms = watch.elapsedMilliseconds;
              socket.destroy();
            } catch (_) {
              ms = null;
            }
          }
        } else {
          ms = await api?.delay(
            name,
            provider: liveProxies[name]?['provider-name'] as String?,
          );
        }
        if (mounted) setState(() => (tcp ? tcpLatency : latency)[name] = ms);
      }
    }

    await Future.wait(List.generate(4, (_) => worker()));
    if (mounted) setState(() => testing = false);
  }

  List<Widget> _liveWidgets() {
    if (core.api == null) {
      return [const Text('启动后将按订阅原有代理组显示节点，远程 Provider 由内核加载。')];
    }
    final groups = liveProxies.entries
        .where((e) => e.value is Map && e.value['all'] is List)
        .toList();
    final group =
        groups.where((g) => g.key == chosenGroup).firstOrNull ??
        groups.where((g) => g.key != 'GLOBAL').firstOrNull ??
        groups.firstOrNull;
    var names = group == null || chosenGroup == '*'
        ? liveProxies.keys.toList()
        : (group.value['all'] as List).cast<String>().toList();
    names = names
        .where((n) => n.toLowerCase().contains(nodeFilter.toLowerCase()))
        .toList();
    if (sorting) {
      names.sort(
        (a, b) =>
            (latency[a] ?? 0x7fffffff).compareTo(latency[b] ?? 0x7fffffff),
      );
    }
    final selectable = group?.value['type'] == 'Selector';
    return [
      Wrap(
        spacing: 8,
        children: [
          for (final entry in {
            'rule': '规则',
            'global': '全局',
            'direct': '直连',
          }.entries)
            ChoiceChip(
              label: Text(entry.value),
              selected: routing == entry.key,
              onSelected: busy
                  ? null
                  : (_) => _action(() async {
                      await core.api!.setMode(entry.key);
                      await _refreshLive();
                    }),
            ),
        ],
      ),
      const Text('默认沿用订阅分流。手动组可切换；自动测速、故障转移与负载均衡组由内核决定。'),
      Wrap(
        spacing: 8,
        children: [
          for (final g in groups)
            ChoiceChip(
              label: Text('${g.key} · ${g.value['type']}'),
              selected: chosenGroup != '*' && group?.key == g.key,
              onSelected: (_) => setState(() => chosenGroup = g.key),
            ),
          ChoiceChip(
            label: const Text('全部节点'),
            selected: chosenGroup == '*',
            onSelected: (_) => setState(() => chosenGroup = '*'),
          ),
        ],
      ),
      TextField(
        onChanged: (value) => setState(() => nodeFilter = value),
        decoration: const InputDecoration(labelText: '搜索节点'),
      ),
      Wrap(
        spacing: 8,
        children: [
          OutlinedButton(
            onPressed: testing
                ? null
                : () => _testNodes(
                    group == null || chosenGroup == '*'
                        ? liveProxies.keys.toList()
                        : (group.value['all'] as List).cast<String>(),
                  ),
            child: const Text('全组真连接测速'),
          ),
          OutlinedButton(
            onPressed: testing
                ? null
                : () => _testNodes(
                    group == null || chosenGroup == '*'
                        ? liveProxies.keys.toList()
                        : (group.value['all'] as List).cast<String>(),
                    tcp: true,
                  ),
            child: const Text('全组 TCP 测速'),
          ),
          FilterChip(
            label: const Text('按延迟排序'),
            selected: sorting,
            onSelected: (v) => setState(() => sorting = v),
          ),
        ],
      ),
      if (testing) const LinearProgressIndicator(),
      const Text('TCP 只测服务器握手；真连接由内核走代理测试。远程节点未暴露服务器时 TCP 显示不可用。'),
      for (final node in names)
        ListTile(
          title: Text(node),
          selected: group?.value['now'] == node,
          subtitle: Text(
            '${liveProxies[node]?['type'] ?? '代理组'} · 真连接 ${latency.containsKey(node) ? '${latency[node] ?? '失败'} ms' : '未测'} · TCP ${tcpLatency.containsKey(node) ? '${tcpLatency[node] ?? '不可用'} ms' : '未测'}',
          ),
          trailing: IconButton(
            tooltip: '测试 $node',
            icon: const Icon(Icons.speed),
            onPressed: testing ? null : () => _testNodes([node]),
          ),
          onTap: !selectable || chosenGroup == '*' || busy
              ? null
              : () => _action(() async {
                  await core.api!.select(group!.key, node);
                  await _refreshLive();
                }),
        ),
      for (final entry in providers.entries.where((e) => e.key != 'default'))
        ExpansionTile(
          title: Text('节点集 · ${entry.key}'),
          subtitle: Text(
            '${(entry.value['proxies'] as List?)?.length ?? 0} 个节点',
          ),
          trailing: IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _action(() => core.api!.updateProvider(entry.key)),
          ),
          children: [
            for (final node in (entry.value['proxies'] as List? ?? []))
              ListTile(
                title: Text(node['name'] as String),
                subtitle: Text('${node['type']} · 来源：${entry.key}'),
                trailing: Text(
                  latency.containsKey('${entry.key}/${node['name']}')
                      ? '${latency['${entry.key}/${node['name']}'] ?? '失败'} ms'
                      : '未测',
                ),
                onTap: () => _action(() async {
                  final ms = await core.api!.delay(
                    node['name'] as String,
                    provider: entry.key,
                  );
                  if (mounted) {
                    setState(
                      () => latency['${entry.key}/${node['name']}'] = ms,
                    );
                  }
                }),
              ),
          ],
        ),
      ExpansionTile(
        title: Text('远程规则集 · ${ruleProviders.length}'),
        children: [
          for (final entry in ruleProviders.entries)
            ListTile(
              title: Text(entry.key),
              subtitle: Text('${entry.value['ruleCount'] ?? '—'} 条规则'),
              trailing: IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: () => _action(
                  () => core.api!.updateProvider(entry.key, rules: true),
                ),
              ),
            ),
        ],
      ),
      ExpansionTile(
        title: Text(
          '连接 · ${connections.length} · ↑ ${(upload / 1024).toStringAsFixed(1)} / ↓ ${(download / 1024).toStringAsFixed(1)} KB/s',
        ),
        children: [
          for (final c in connections)
            ListTile(
              title: Text(
                '${c['metadata']?['host'] ?? c['metadata']?['destinationIP'] ?? ''}:${c['metadata']?['destinationPort'] ?? ''}',
              ),
              subtitle: Text('${c['chains']} · ${c['rule']}'),
              trailing: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () =>
                    _action(() => core.api!.closeConnection(c['id'] as String)),
              ),
            ),
        ],
      ),
      ExpansionTile(
        title: const Text('实时内核日志（本机最近 200 条）'),
        children: [for (final line in logs.reversed) SelectableText(line)],
      ),
      const Divider(height: 32),
    ];
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
    if (hasBackup && systemProxySupported) {
      try {
        final journal = jsonDecode(await bf.readAsString()) as Map;
        if (journal['owned'] is String) await _restoreLeftover();
      } catch (_) {
        /* Keep recovery available if the journal cannot be read. */
      }
    }
  }

  Future<void> _validateCandidate(
    Map<String, dynamic> config,
    ImportMode importMode,
  ) async {
    final candidate = ProxyConfigBuilder.build(
      profileConfig: config,
      mode: importMode,
      selectedNode:
          ((config['proxies'] as List?)?.firstOrNull?['name'] as String?) ?? '',
    );
    await _validateRuntime(candidate);
  }

  Future<void> _validateRuntime(Map<String, dynamic> candidate) async {
    final validator = MihomoController();
    final directory = Directory('${storeFile!.parent.path}/validation/check');
    try {
      await validator.startRuntime(
        exePath.text.trim(),
        directory,
        runtimeConfig: candidate,
        mixedPort: await MihomoController.findFreePort(),
      );
    } finally {
      await validator.dispose();
    }
  }

  String _cardSubtitle(StoredProfile profile) {
    final kind = profile.isAggregate
        ? '聚合订阅 · ${profile.sourceUrls.length} 个来源'
        : profile.mode == ImportMode.fullConfig
        ? '完整配置'
        : '仅节点';
    final updated = profile.updatedAt == null
        ? '尚未更新'
        : '更新于 ${profile.updatedAt!.toLocal().toString().split('.').first}';
    return '$kind · ${profile.nodeNames.length} 个本地节点 / ${profile.providerCount} 个远程节点集 · $updated';
  }

  /// FlClash-style add sheet: one entry point instead of a long form.
  /// QR scanning is intentionally absent on desktop (no camera path);
  /// link / file / paste / aggregate / custom cover every desktop input.
  Future<void> _showAddDialog() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('添加配置'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('链接'),
              subtitle: const Text('通过订阅链接获取配置文件'),
              onTap: () {
                Navigator.of(dialogContext).pop();
                _importDialog(kind: 'link');
              },
            ),
            ListTile(
              leading: const Icon(Icons.file_upload),
              title: const Text('文件'),
              subtitle: const Text('从本地配置文件路径导入'),
              onTap: () {
                Navigator.of(dialogContext).pop();
                _importDialog(kind: 'file');
              },
            ),
            ListTile(
              leading: const Icon(Icons.paste),
              title: const Text('粘贴内容'),
              subtitle: const Text('粘贴配置、Base64 订阅或节点链接'),
              onTap: () {
                Navigator.of(dialogContext).pop();
                _importDialog(kind: 'paste');
              },
            ),
            ListTile(
              leading: const Icon(Icons.merge),
              title: const Text('聚合订阅'),
              subtitle: const Text('多个订阅链接合并成一个配置使用'),
              onTap: () {
                Navigator.of(dialogContext).pop();
                _aggregateDialog();
              },
            ),
            ListTile(
              leading: const Icon(Icons.tune),
              title: const Text('自定义'),
              subtitle: const Text('粘贴完整配置，再在卡片上覆写策略组与规则'),
              onTap: () {
                Navigator.of(dialogContext).pop();
                setState(() => mode = ImportMode.fullConfig);
                _importDialog(kind: 'paste');
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _importDialog({required String kind}) async {
    final field = kind == 'link'
        ? url
        : kind == 'file'
        ? filePath
        : content;
    final fieldLabel = kind == 'link'
        ? 'HTTPS 订阅地址'
        : kind == 'file'
        ? '配置文件路径'
        : '粘贴配置、Base64 订阅或节点链接';
    var dialogMode = mode;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(
            kind == 'link'
                ? '通过链接添加'
                : kind == 'file'
                ? '通过文件添加'
                : '粘贴内容添加',
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  decoration: const InputDecoration(
                    labelText: '订阅名称（可空）',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButton<ImportMode>(
                  value: dialogMode,
                  isExpanded: true,
                  onChanged: (v) => setDialogState(() => dialogMode = v!),
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
                const SizedBox(height: 12),
                TextField(
                  controller: field,
                  minLines: kind == 'paste' ? 4 : 1,
                  maxLines: kind == 'paste' ? 8 : 1,
                  decoration: InputDecoration(
                    labelText: fieldLabel,
                    border: const OutlineInputBorder(),
                  ),
                ),
                if (kind == 'file')
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text('桌面版暂无系统文件选择器，请填写配置文件的完整路径。'),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                setState(() => mode = dialogMode);
                Navigator.of(dialogContext).pop();
                if (kind == 'file') {
                  await _importFile();
                } else {
                  await _import(kind == 'link');
                }
              },
              child: Text(kind == 'link' ? '下载并保存' : '检查并保存'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _importFile() async {
    final path = filePath.text.trim();
    if (path.isEmpty) {
      if (mounted) setState(() => importMsg = '请先填写配置文件的完整路径。');
      return;
    }
    try {
      content.text = await File(path).readAsString();
    } catch (_) {
      if (mounted) {
        setState(() => importMsg = '读取文件失败：请检查路径是否存在且可读。');
      }
      return;
    }
    await _import(false);
  }

  Future<void> _selectAndStart(StoredProfile profile, String node) async {
    await _select(profile, node);
    if (!mounted || core.status == CoreStatus.running) return;
    await _toggleProxy();
  }

  Future<void> _aggregateDialog({StoredProfile? existing}) async {
    name.text = existing?.name ?? '';
    aggregateUrls.text = existing == null ? '' : existing.sourceUrls.join('\n');
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(existing == null ? '新建聚合订阅' : '管理聚合来源'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                decoration: const InputDecoration(
                  labelText: '聚合名称（可空）',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: aggregateUrls,
                minLines: 4,
                maxLines: 10,
                decoration: const InputDecoration(
                  labelText: '订阅地址，每行一个',
                  border: OutlineInputBorder(),
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  '只合并各源的节点（节点模式）；重名节点自动加来源后缀，不会静默丢弃。完整配置的策略组与规则不参与合并。',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.of(dialogContext).pop();
              await _saveAggregate(existing);
            },
            child: Text(existing == null ? '创建聚合订阅' : '保存来源并更新'),
          ),
        ],
      ),
    );
  }

  Future<void> _saveAggregate(StoredProfile? existing) async {
    final s = store;
    if (s == null || busy) return;
    late final List<String> urls;
    try {
      urls = parseAggregateUrls(aggregateUrls.text);
    } catch (e) {
      if (mounted) setState(() => importMsg = '聚合订阅创建失败：$e');
      return;
    }
    setState(() => busy = true);
    try {
      final sources = <({String label, Map<String, dynamic> config})>[];
      final failures = <String>[];
      for (var i = 0; i < urls.length; i++) {
        try {
          final response = await ProfileImporter.fetchSubscription(
            Uri.parse(urls[i]),
            proxyPort: core.api == null ? null : core.mixedPort,
          );
          final parsed = ProfileImporter.parse(
            response.body,
            ImportMode.nodesOnly,
          );
          sources.add((
            label: Uri.parse(urls[i]).host.isEmpty
                ? '来源${i + 1}'
                : Uri.parse(urls[i]).host,
            config: parsed.config,
          ));
        } catch (_) {
          failures.add('来源${i + 1}（${Uri.parse(urls[i]).host}）拉取失败');
        }
      }
      final merged = mergeAggregateConfigs(sources);
      final nodes = merged['proxies'] as List;
      if (nodes.isEmpty) {
        if (mounted) {
          setState(
            () => importMsg =
                '聚合订阅失败：所有来源均无可用节点。${failures.isEmpty ? '' : failures.join('；')}',
          );
        }
        return;
      }
      if (desktopEnabled && await File(exePath.text.trim()).exists()) {
        await _validateCandidate(merged, ImportMode.nodesOnly);
      }
      if (existing == null) {
        final saved = await s.add(
          name: name.text.trim().isEmpty ? '聚合订阅' : name.text.trim(),
          mode: ImportMode.nodesOnly,
          source: 'aggregate',
          config: merged,
          activate: core.status != CoreStatus.running,
          sourceUrls: urls,
        );
        if (mounted) {
          setState(
            () => importMsg =
                '已保存聚合「${saved.name}」：${nodes.length} 个节点（${urls.length} 个来源）。${failures.isEmpty ? '' : '注意：${failures.join('；')}'}',
          );
        }
      } else {
        final next = StoredProfile.fromJson({
          ...existing.toJson(),
          'config': merged,
          'sourceUrls': urls,
          'updatedAt': DateTime.now().toIso8601String(),
        });
        await s.replace(next);
        if (mounted) {
          setState(
            () => importMsg =
                '聚合「${existing.name}」已更新：${nodes.length} 个节点。${failures.isEmpty ? '' : '注意：${failures.join('；')}'}',
          );
        }
      }
    } catch (_) {
      if (mounted) {
        setState(() => importMsg = '聚合订阅失败：旧订阅完整保留，请检查各源地址与格式。');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _updateAggregate(StoredProfile profile) async {
    aggregateUrls.text = profile.sourceUrls.join('\n');
    await _saveAggregate(profile);
  }

  Future<void> _showAggregateExport(StoredProfile profile) async {
    final json = const JsonEncoder.withIndent('  ').convert(profile.config);
    final encoded = base64Encode(utf8.encode(json));
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('导出聚合「${profile.name}」'),
        content: Text(
          '${profile.nodeNames.length} 个节点，配置 JSON 约 ${(json.length / 1024).toStringAsFixed(1)} KB。\n\n'
          'Base64 配置可粘贴给接受 Base64 配置的客户端；JSON 文件可直接作为 Mihomo 配置文件使用。'
          '导出的内容包含你的节点信息，请勿公开分享。节点链接（URI）格式导出暂不支持：各协议反向编码容易丢失参数，宁可不做假导出。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: encoded));
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('聚合配置 Base64 已复制。')),
                );
              }
            },
            child: const Text('复制 Base64'),
          ),
          FilledButton(
            onPressed: () async {
              try {
                final dir = Directory('${storeFile!.parent.path}/exports');
                await dir.create(recursive: true);
                final file = File('${dir.path}/aggregate-${profile.id}.json');
                await file.writeAsString(json);
                if (mounted) {
                  setState(() => importMsg = '聚合配置已保存到：${file.path}');
                }
              } catch (_) {
                if (mounted) {
                  setState(() => importMsg = '导出文件失败：请检查导出目录写入权限。');
                }
              }
              if (dialogContext.mounted) Navigator.of(dialogContext).pop();
            },
            child: const Text('保存 JSON 文件'),
          ),
        ],
      ),
    );
  }

  List<Widget> _savedNodeTiles(StoredProfile profile, bool running) {
    if (widget.panel == 'config') return const [];
    if (running && activeProfileId == profile.id) return const [];
    final query = nodeFilter.toLowerCase();
    final names = profile.nodeNames
        .where((n) => n.toLowerCase().contains(query))
        .toList();
    final s = store;
    return [
      for (final node in names)
        ListTile(
          dense: true,
          leading: Icon(
            s?.selectedProfileId == profile.id && s?.selectedNode == node
                ? Icons.radio_button_checked
                : Icons.radio_button_unchecked,
          ),
          title: Text(node),
          subtitle: Text(
            profile.nodes
                    .where((n) => n['name'] == node)
                    .firstOrNull?['type']
                    ?.toString() ??
                '节点',
          ),
          trailing: IconButton(
            tooltip: '选择并启动',
            icon: const Icon(Icons.play_arrow),
            onPressed: busy ? null : () => _selectAndStart(profile, node),
          ),
          onTap: busy ? null : () => _select(profile, node),
        ),
    ];
  }

  Future<void> _import(bool remote) async {
    final s = store;
    if (s == null || busy) return;
    setState(() => busy = true);
    try {
      final response = remote
          ? await ProfileImporter.fetchSubscription(
              Uri.parse(url.text.trim()),
              proxyPort: core.api == null ? null : core.mixedPort,
            )
          : null;
      final text = response?.body ?? content.text;
      final parsed = ProfileImporter.parse(text, mode);
      if (desktopEnabled && await File(exePath.text.trim()).exists()) {
        await _validateCandidate(parsed.config, mode);
      }
      final fallback = remote
          ? (Uri.tryParse(url.text.trim())?.host ?? '订阅')
          : ((parsed.config['proxies'] as List?)?.firstOrNull?['name']
                    ?.toString() ??
                '本地配置');
      final saved = await s.add(
        name: name.text.trim().isEmpty ? fallback : name.text.trim(),
        mode: mode,
        source: remote ? 'url' : 'paste',
        config: parsed.config,
        sourceUrl: remote ? url.text.trim() : null,
        userInfo: response?.userInfo,
        activate: core.status != CoreStatus.running,
      );
      if (mounted) {
        setState(
          () => importMsg =
              '已保存「${saved.name}」：${saved.nodeNames.length} 个本地节点、${saved.providerCount} 个远程节点集，${core.status == CoreStatus.running ? '当前连接保持原配置。' : '已设为当前配置。'}远程节点启动后完整读取。',
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
    if (s == null || busy) return;
    if (core.status == CoreStatus.running && activeProfileId != profile.id) {
      setState(() => proxyMsg = '切换订阅前请先停止代理，再选择并重新启动。');
      return;
    }
    setState(() => busy = true);
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
    } finally {
      if (mounted) setState(() => busy = false);
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
        if (profile == null) {
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
        runtimeDir = Directory(
          '${storeFile!.parent.path}/runtime/${profile.id}',
        );
        final config = await ProfileOverrides.buildRuntime(
          source: profile.config,
          mode: profile.mode,
          selectedNode: node ?? '',
          overlay: profile.merge,
          script: profile.script,
        );
        core.serviceMode = useService && serviceReady;
        await core.startRuntime(
          exePath.text.trim(),
          runtimeDir!,
          runtimeConfig: config,
          mixedPort: port,
        );
        activeProfileId = profile.id;
        latency.clear();
        tcpLatency.clear();
        logs.clear();
        upload = 0;
        download = 0;
        String? group;
        if (core.api != null &&
            node != null &&
            profile.mode == ImportMode.nodesOnly) {
          group = await core.api!.selectNode(node);
        }
        await _refreshLive();
        _startStreams();
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
        await writeTextAtomically(
          bf,
          jsonEncode({
            ...current.toJson(),
            'owned': '127.0.0.1:${core.mixedPort}',
          }),
        );
        try {
          if (Platform.isWindows && widget.systemProxyAdapter == null) {
            await guardian.arm(core.processId!, '127.0.0.1:${core.mixedPort}');
          }
          await systemProxy.enable('127.0.0.1:${core.mixedPort}');
        } catch (_) {
          try {
            await systemProxy.restore(current);
            await guardian.cancel();
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
          await guardian.cancel();
          await bf.delete();
        }
        await guardian.cancel();
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
      final journal = jsonDecode(await bf.readAsString()) as Map;
      final current = await systemProxy.read();
      if (journal['owned'] == null ||
          (current.enable == true && current.server == journal['owned'])) {
        await systemProxy.restore(saved);
      }
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
    subscriptionTimer?.cancel();
    updateTimer?.cancel();
    unawaited(logStream?.cancel());
    unawaited(trafficStream?.cancel());
    if (widget.systemProxyAdapter == null) {
      DesktopIntegration.channel.setMethodCallHandler(null);
    }
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
    for (final c in [
      content,
      url,
      name,
      exePath,
      portField,
      aggregateUrls,
      filePath,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = store;
    final running = core.status == CoreStatus.running;
    return Scaffold(
      // No nested AppBar: the dashboard already has one. The panel title
      // and actions live in the body so the page has a single top bar.
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.panel == 'config' ? '配置' : '节点',
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              if (widget.panel != 'config') ...[
                IconButton(
                  tooltip: running ? '停止代理' : '启动代理',
                  onPressed: busy || s == null ? null : _toggleProxy,
                  icon: Icon(
                    running
                        ? Icons.stop_circle_outlined
                        : Icons.play_circle_outline,
                  ),
                ),
                if (systemProxySupported)
                  IconButton(
                    tooltip: systemProxyOn ? '关闭系统代理' : '开启系统代理',
                    onPressed:
                        !running ||
                            busy ||
                            proxyChanging ||
                            (leftoverBackup && !systemProxyOn)
                        ? null
                        : () => _action(() => _setSystemProxy(!systemProxyOn)),
                    icon: Icon(systemProxyOn ? Icons.public : Icons.public_off),
                  ),
              ],
            ],
          ),
          const SizedBox(height: 16),
          if (widget.panel != 'nodes') ...[
            const Text(
              '导入 → 保存 → 选节点 → 启动代理。协议：SOCKS5、HTTP(S)、Trojan、SS、VMess、VLESS、Hysteria2；其他参数会明确拒绝，不静默丢弃。',
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: busy || s == null ? null : _showAddDialog,
                  icon: const Icon(Icons.add),
                  label: const Text('添加配置'),
                ),
                const SizedBox(width: 12),
                const Expanded(child: Text('链接、文件、粘贴、聚合订阅与自定义，与 FL 的添加方式对齐。')),
              ],
            ),
            const SizedBox(height: 12),
            Text(importMsg),
          ],
          if (widget.panel != 'config' && !running) ...[
            TextField(
              onChanged: (value) => setState(() => nodeFilter = value),
              decoration: const InputDecoration(
                labelText: '搜索节点',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
          ],
          const Divider(height: 40),
          if (s == null)
            const Center(child: CircularProgressIndicator())
          else if (s.profiles.isEmpty)
            const Text('还没有保存的订阅。导入后，节点会列在这里供选择。')
          else
            for (final profile in s.profiles) ...[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              profile.name,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                            ),
                          ),
                          if (s.selectedProfileId == profile.id)
                            const Padding(
                              padding: EdgeInsets.only(right: 8),
                              child: Icon(
                                Icons.check_circle,
                                color: Color(0xffc7e9a3),
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
                      Text(_cardSubtitle(profile)),
                      if (widget.panel != 'nodes') ...[
                        Text(_profileSummary(profile)),
                        Wrap(
                          spacing: 8,
                          children: [
                            TextButton(
                              onPressed: busy || running
                                  ? null
                                  : () => _select(
                                      profile,
                                      profile.nodeNames.firstOrNull ?? '',
                                    ),
                              child: Text(
                                s.selectedProfileId == profile.id
                                    ? '当前配置'
                                    : '使用此配置',
                              ),
                            ),
                            TextButton(
                              onPressed:
                                  busy ||
                                      (profile.isAggregate
                                          ? profile.sourceUrls.isEmpty
                                          : profile.sourceUrl == null)
                                  ? null
                                  : () => profile.isAggregate
                                        ? _updateAggregate(profile)
                                        : _updateProfile(profile),
                              child: Text(
                                profile.isAggregate ? '更新全部' : '更新订阅',
                              ),
                            ),
                            TextButton(
                              onPressed: busy || running
                                  ? null
                                  : () => _editOverrides(profile),
                              child: const Text('覆写与更新设置'),
                            ),
                            if (profile.isAggregate) ...[
                              TextButton(
                                onPressed: busy
                                    ? null
                                    : () => _aggregateDialog(existing: profile),
                                child: const Text('管理来源'),
                              ),
                              TextButton(
                                onPressed: busy
                                    ? null
                                    : () => _showAggregateExport(profile),
                                child: const Text('导出聚合'),
                              ),
                            ],
                          ],
                        ),
                      ],
                      ..._savedNodeTiles(profile, running),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
          const Divider(height: 40),
          if (widget.panel != 'config') ...[
            ..._liveWidgets(),
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
          if (Platform.isWindows)
            SwitchListTile(
              title: const Text('开机自启 · 静默到托盘'),
              value: autostart,
              onChanged: (v) => _action(() async {
                await DesktopIntegration.autostart(v);
                if (mounted) setState(() => autostart = v);
              }),
            ),
          if (Platform.isWindows && widget.panel != 'nodes') ...[
            SwitchListTile(
              title: const Text('Windows 服务承载内核'),
              value: useService,
              subtitle: Text(
                serviceReady
                    ? '已安装 · 日常启动无需 UAC；当前服务以 LocalService 运行，TUN 下一阶段开放。'
                    : serviceInstalled
                    ? '服务已安装但尚未就绪，可卸载后重装；普通模式仍可使用。'
                    : '可选安装需要一次管理员授权，普通系统代理无需安装服务。',
              ),
              onChanged: busy || running || !serviceReady
                  ? null
                  : _preferService,
            ),
            TextButton(
              onPressed: busy || running
                  ? null
                  : () => _manageService(!serviceInstalled),
              child: Text(
                serviceInstalled
                    ? '卸载 Windows 服务（管理员授权）'
                    : '安装 Windows 服务（一次管理员授权）',
              ),
            ),
            Text(updateMessage),
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: updating ? null : _checkUpdate,
                  child: const Text('检查软件更新'),
                ),
                if (availableUpdate != null)
                  FilledButton(
                    onPressed: updating || busy ? null : _installUpdate,
                    child: const Text('下载并安装更新（将退出应用）'),
                  ),
              ],
            ),
          ],
          if (Platform.isWindows)
            OutlinedButton(
              onPressed: busy ? null : _exit,
              child: const Text('退出并恢复系统代理'),
            ),
        ],
      ),
    );
  }
}
