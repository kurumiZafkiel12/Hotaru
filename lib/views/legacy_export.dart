import 'dart:io';

import 'package:hotaru/common/common.dart';
import 'package:hotaru/common/legacy_export.dart';
import 'package:hotaru/widgets/widgets.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

class LegacyExportView extends StatefulWidget {
  const LegacyExportView({super.key});

  @override
  State<LegacyExportView> createState() => _LegacyExportViewState();
}

class _LegacyExportViewState extends State<LegacyExportView> {
  bool _busy = false;
  String _message = '';

  Future<void> _export() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final picked = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      final source = picked?.path;
      if (source == null) return;
      final folder = await FilePicker.getDirectoryPath();
      if (folder == null) return;
      final output = await compute(exportLegacyProfiles, (
        source: source,
        destination:
            '$folder${Platform.pathSeparator}Hotaru-legacy-${DateTime.now().microsecondsSinceEpoch}',
      ));
      if (mounted) setState(() => _message = output);
    } catch (error) {
      if (mounted) setState(() => _message = compactError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.appLocalizations;
    return CommonScaffold(
      title: l.legacyExport,
      body: ListView(
        padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + context.bottomInset),
        children: [
          Text(l.legacyExportDesc),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _busy ? null : _export,
            child: Text(l.legacyExport),
          ),
          if (_busy) const LinearProgressIndicator(),
          const SizedBox(height: 20),
          SelectableText(_message),
        ],
      ),
    );
  }
}
