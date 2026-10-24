import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'profiles/profiles_page.dart';
import 'storage/atomic_file.dart';

/// Validates decoded layout data: a JSON list of unique widget ids in range.
/// Returns null for any other shape so callers can fall back with a warning
/// instead of silently accepting a corrupt or foreign file.
List<int>? tryParseLayout(Object? data, int itemCount) {
  if (data is! List) return null;
  final result = <int>[];
  for (final value in data) {
    if (value is! int || value < 0 || value >= itemCount) return null;
    if (!result.contains(value)) result.add(value);
  }
  return result;
}

/// Writes the layout atomically (temp file + rename); see
/// [writeTextAtomically]. The temp file never remains after success.
Future<void> writeLayoutAtomically(File file, List<int> cards) =>
    writeTextAtomically(file, jsonEncode(cards));

class Dashboard extends StatefulWidget {
  final Widget diagnostic;
  final File? storageFile;
  const Dashboard({super.key, required this.diagnostic, this.storageFile});
  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> {
  static const labels = ['连接状态', '实时流量', '当前节点', '出口 IP', '订阅用量', '快捷测速'];
  List<int> cards = [0, 1, 2, 3];
  int page = 0;
  bool editing = false;
  String connectionSummary = '代理未启动';
  bool loaded = false;
  String? warning;
  Future<void> writes = Future.value();
  File? get layoutFile {
    if (widget.storageFile != null) return widget.storageFile;
    final base = Platform.isWindows
        ? Platform.environment['APPDATA']
        : Platform.environment['HOME'];
    if (base == null) return null;
    return File('$base/Hotaru/layout-v1.json');
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final file = layoutFile;
      if (file != null && await file.exists()) {
        final parsed = tryParseLayout(
          jsonDecode(await file.readAsString()),
          labels.length,
        );
        // A present-but-invalid file is corruption, not a fresh install:
        // surface the same fallback warning as an unreadable file.
        if (parsed == null) throw const FormatException('Invalid layout');
        cards = parsed;
      }
    } catch (_) {
      warning = '布局读取失败，已使用默认布局。';
    }
    if (mounted) setState(() => loaded = true);
  }

  void save() {
    // Snapshot now; writes stay serialized so renames cannot interleave.
    final snapshot = List<int>.of(cards);
    writes = writes.then((_) async {
      try {
        final file = layoutFile;
        if (file == null) throw const FileSystemException();
        await writeLayoutAtomically(file, snapshot);
      } catch (_) {
        if (mounted) setState(() => warning = '布局保存失败，当前修改仅在本次运行有效。');
      }
    });
  }

  Widget card(int id) => Container(
    key: ValueKey(id),
    margin: const EdgeInsets.only(bottom: 16),
    padding: const EdgeInsets.all(24),
    decoration: BoxDecoration(
      color: id == 0 ? const Color(0xff293b30) : const Color(0xff202c2e),
      borderRadius: BorderRadius.circular(24),
      border: Border.all(color: const Color(0xff394a41)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                labels[id],
                style: const TextStyle(color: Color(0xffc7e9a3)),
              ),
            ),
            if (editing)
              IconButton(
                tooltip: '移除${labels[id]}',
                onPressed: () {
                  setState(() => cards.remove(id));
                  save();
                },
                icon: const Icon(Icons.close),
              ),
          ],
        ),
        const SizedBox(height: 18),
        Text(
          [
            connectionSummary,
            '— KB/s',
            '在节点页选择',
            '待检测',
            '— GB',
            '准备好，再出发。',
          ][id],
          style: const TextStyle(fontSize: 26),
        ),
        const SizedBox(height: 12),
        Text(
          [
            '在节点页启动代理；切换页面后保持连接。TUN 尚未接入。',
            '接入实际代理连接后显示流量',
            '在「节点」页导入、保存并选择节点后启动代理',
            '不会显示模拟 IP 地址',
            '订阅保存与用量统计开发中',
            '延迟与下载测速开发中',
          ][id],
          style: const TextStyle(color: Color(0xffa5b6ad)),
        ),
      ],
    ),
  );
  Widget home() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          const Expanded(
            child: Text('一点微光，自在连接。', style: TextStyle(fontSize: 28)),
          ),
          TextButton(
            onPressed: loaded ? () => setState(() => editing = !editing) : null,
            child: Text(editing ? '完成' : '自定义'),
          ),
        ],
      ),
      const SizedBox(height: 12),
      const Text('我的桌面 / 可定制小组件', style: TextStyle(color: Color(0xffb0c49d))),
      if (warning != null) Text(warning!),
      if (editing)
        Wrap(
          spacing: 8,
          children: [
            for (var i = 0; i < labels.length; i++)
              if (!cards.contains(i))
                ActionChip(
                  label: Text('＋ ${labels[i]}'),
                  onPressed: () {
                    setState(() => cards.add(i));
                    save();
                  },
                ),
            ActionChip(
              label: const Text('恢复默认'),
              onPressed: () {
                setState(() => cards = [0, 1, 2, 3]);
                save();
              },
            ),
          ],
        ),
      const SizedBox(height: 24),
      Expanded(
        child: !loaded
            ? const Center(child: CircularProgressIndicator())
            : cards.isEmpty
            ? const Center(child: Text('点击自定义，添加你关心的小组件。'))
            : editing
            ? ReorderableListView(
                onReorderItem: (oldIndex, newIndex) {
                  setState(() {
                    final item = cards.removeAt(oldIndex);
                    cards.insert(newIndex, item);
                  });
                  save();
                },
                children: cards.map(card).toList(),
              )
            : ListView(children: cards.map(card).toList()),
      ),
    ],
  );
  Widget toolbox() => ListView(
    children: [
      const Text('网络工具箱', style: TextStyle(fontSize: 28)),
      const SizedBox(height: 24),
      for (final name in ['节点测速', '出口 IP', 'IP 质量', 'DNS 诊断'])
        Card(
          child: ListTile(
            leading: const Icon(Icons.insights),
            title: Text(name),
            subtitle: const Text('等待代理能力接入'),
            trailing: const Chip(label: Text('开发中')),
          ),
        ),
      const SizedBox(height: 20),
      FilledButton.tonal(
        onPressed: () => Navigator.of(context)
            .push(MaterialPageRoute<void>(builder: (_) => widget.diagnostic)),
        child: const Text('打开内核诊断'),
      ),
    ],
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xff111a1c),
    appBar: AppBar(
      title: const Text('✦ Hotaru · 蛍'),
      actions: [
        IconButton(
          tooltip: '开源许可',
          onPressed: () => showLicensePage(
            context: context,
            applicationName: 'Hotaru',
            applicationVersion: '0.4.0',
          ),
          icon: const Icon(Icons.info_outline),
        ),
        if (Platform.isWindows)
          TextButton(
            onPressed: () async {
              await Process.start('rundll32.exe', [
                'url.dll,FileProtocolHandler',
                'https://github.com/kurumiZafkiel12/Hotaru/releases',
              ]);
            },
            child: const Text('下载更新'),
          ),
        const Padding(padding: EdgeInsets.all(16), child: Text('Hotaru v0.4')),
      ],
    ),
    body: Padding(
      padding: const EdgeInsets.all(24),
      child: IndexedStack(
        index: page,
        children: [
          home(),
          toolbox(),
          ProfilesPage(
            onConnectionChanged: (value) {
              if (mounted && connectionSummary != value) {
                setState(() => connectionSummary = value);
              }
            },
          ),
        ],
      ),
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: page,
      onDestinationSelected: (v) => setState(() => page = v),
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.dashboard_outlined),
          label: '桌面',
        ),
        NavigationDestination(icon: Icon(Icons.widgets_outlined), label: '工具箱'),
        NavigationDestination(icon: Icon(Icons.download_outlined), label: '节点'),
      ],
    ),
  );
}
