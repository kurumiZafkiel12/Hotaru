import 'dart:io';

import 'package:hotaru/common/common.dart';
import 'package:hotaru/common/network_diagnostics.dart';
import 'package:hotaru/features/ip_quality/ip_quality_sheet.dart';
import 'package:hotaru/ui/icons/icons.dart';
import 'package:hotaru/widgets/widgets.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

class NetworkDiagnosticsView extends StatefulWidget {
  const NetworkDiagnosticsView({
    super.key,
    this.diagnostics = const NetworkDiagnostics(),
  });

  final NetworkDiagnostics diagnostics;

  @override
  State<NetworkDiagnosticsView> createState() => _NetworkDiagnosticsViewState();
}

class _NetworkDiagnosticsViewState extends State<NetworkDiagnosticsView> {
  final _input = TextEditingController();
  DiagnosticKind _kind = DiagnosticKind.dns;
  String _result = '';
  bool _busy = false;
  bool _failed = false;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    if (_busy || _input.text.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _failed = false;
      _result = '';
    });
    try {
      final result = await widget.diagnostics.run(_kind, _input.text);
      if (mounted) setState(() => _result = result);
    } catch (error) {
      if (mounted) {
        setState(() {
          _failed = true;
          _result = compactError(error);
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _quality() async {
    try {
      final host = widget.diagnostics.hostOf(_input.text);
      if (InternetAddress.tryParse(host) == null) {
        throw const FormatException('Enter an IPv4 or IPv6 address');
      }
      await showIpQualitySheet(context, ip: host);
    } catch (error) {
      if (mounted) setState(() => _result = compactError(error));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.appLocalizations;
    return CommonScaffold(
      title: l.networkDiagnostics,
      body: ListView(
        padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + context.bottomInset),
        children: [
          Text(l.networkDiagnosticsDesc),
          const SizedBox(height: 20),
          SegmentedButton<DiagnosticKind>(
            segments: const [
              ButtonSegment(value: DiagnosticKind.dns, label: Text('DNS')),
              ButtonSegment(value: DiagnosticKind.tcp, label: Text('TCP')),
              ButtonSegment(value: DiagnosticKind.http, label: Text('HTTP')),
            ],
            selected: {_kind},
            onSelectionChanged: _busy
                ? null
                : (value) => setState(() {
                    _kind = value.single;
                    _result = '';
                  }),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _input,
            enabled: !_busy,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: l.diagnosticTarget,
              hintText: switch (_kind) {
                DiagnosticKind.dns => 'example.com',
                DiagnosticKind.tcp => 'example.com:443',
                DiagnosticKind.http => 'https://example.com',
              },
            ),
            onSubmitted: (_) => _run(),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton(
                onPressed: _busy ? null : _run,
                child: Text(l.diagnosticRun),
              ),
              TextButton(
                onPressed: _busy ? null : _quality,
                child: Text(l.ipQualityShort),
              ),
              IconButton(
                tooltip: l.copy,
                onPressed: _result.isEmpty
                    ? null
                    : () => Clipboard.setData(ClipboardData(text: _result)),
                icon: const GlyphIcon(AppGlyphs.copy),
              ),
            ],
          ),
          const SizedBox(height: 20),
          if (_busy) const LinearProgressIndicator(),
          if (_result.isNotEmpty)
            SelectableText(
              _result,
              style: TextStyle(
                color: _failed ? context.colorScheme.error : null,
              ),
            ),
        ],
      ),
    );
  }
}
