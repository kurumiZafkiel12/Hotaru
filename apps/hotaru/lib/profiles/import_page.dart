import 'package:flutter/material.dart';

import 'importer.dart';

class ImportPage extends StatefulWidget {
  const ImportPage({super.key});
  @override
  State<ImportPage> createState() => _ImportPageState();
}

class _ImportPageState extends State<ImportPage> {
  final content = TextEditingController(), url = TextEditingController();
  ImportMode mode = ImportMode.nodesOnly;
  String result = '预览只在内存中校验，不保存凭据、不应用代理配置。';
  bool busy = false;
  Future<void> preview(bool remote) async {
    setState(() => busy = true);
    try {
      final text = remote
          ? await ProfileImporter.fetch(Uri.parse(url.text.trim()))
          : content.text;
      final parsed = ProfileImporter.parse(text, mode);
      if (mounted) {
        setState(
          () => result =
              '结构校验通过：${parsed.nodeCount} 个节点。${mode == ImportMode.fullConfig ? '保留原配置字段。' : '仅提取节点。'}尚未执行 Mihomo 配置校验，不代表节点可连接。',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => result = '导入失败：请检查格式、重复名称、端口、HTTPS 地址与 2 MiB 大小限制。暂不支持远程 provider、重定向及其他 URI 协议。',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    content.dispose();
    url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('订阅与节点 · 导入预览')),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text(
          '支持 Mihomo YAML/JSON；单节点支持 SOCKS5、HTTP(S)、基础 Trojan。其他格式会明确拒绝，不静默丢弃参数。',
        ),
        const SizedBox(height: 20),
        DropdownButton<ImportMode>(
          value: mode,
          onChanged: busy ? null : (v) => setState(() => mode = v!),
          items: const [
            DropdownMenuItem(value: ImportMode.nodesOnly, child: Text('仅导入节点')),
            DropdownMenuItem(value: ImportMode.fullConfig, child: Text('完整配置')),
          ],
        ),
        TextField(
          controller: content,
          minLines: 4,
          maxLines: 8,
          enabled: !busy,
          decoration: const InputDecoration(
            labelText: '粘贴配置或节点链接',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: busy ? null : () => preview(false),
          child: const Text('检查粘贴内容'),
        ),
        const SizedBox(height: 24),
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
          onPressed: busy ? null : () => preview(true),
          child: const Text('下载并检查订阅'),
        ),
        const SizedBox(height: 24),
        Text(busy ? '正在检查…' : result),
      ],
    ),
  );
}
