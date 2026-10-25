import 'dart:ffi';

import 'package:flutter/services.dart';
import 'package:hotaru/common/common.dart';
import 'package:hotaru/enum/enum.dart';
import 'package:hotaru/providers/providers.dart';
import 'package:hotaru/state.dart';
import 'package:hotaru/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class LatencyDiagnosticsView extends ConsumerStatefulWidget {
  const LatencyDiagnosticsView({super.key});

  @override
  ConsumerState<LatencyDiagnosticsView> createState() =>
      _LatencyDiagnosticsViewState();
}

class _LatencyDiagnosticsViewState
    extends ConsumerState<LatencyDiagnosticsView> {
  bool _enabled = false;
  String _logPath = '';
  List<Map<String, Object?>> _records = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await latencyDiagnosticsStore.ensureLoaded();
    final path = await latencyDiagnosticsStore.logFilePath;
    final records = await latencyDiagnosticsStore.readRecords();
    if (!mounted) {
      return;
    }
    setState(() {
      _enabled = latencyDiagnosticsStore.enabled;
      _logPath = path;
      _records = records;
    });
  }

  Map<String, Object?> _configSummary() {
    final patch = ref.read(patchClashConfigProvider);
    final appSetting = ref.read(appSettingProvider);
    final packageInfo = globalState.packageInfo;
    return {
      'appVersion': packageInfo.version,
      'appBuild': packageInfo.buildNumber,
      'corePath': appPath.corePath,
      'hostAbi': Abi.current().toString(),
      'coreVersion': 'unavailable',
      'unifiedDelay': patch.unifiedDelay,
      'unifiedDelayForced': patch.generalOverrideKeys.contains(
        GeneralOverrideKey.unifiedDelay,
      ),
      'ipv6': patch.ipv6,
      'ipv6Forced': patch.generalOverrideKeys.contains(GeneralOverrideKey.ipv6),
      'tunEnabled': patch.tun.enable,
      'dnsEnabled': patch.dns.enable,
      'dnsMode': patch.dns.enhancedMode.name,
      'nameserverCount': patch.dns.nameserver.length,
      'fallbackCount': patch.dns.fallback.length,
      'globalTestTarget': patch.testUrl.trim().isEmpty
          ? 'unset'
          : latencySafeTarget(patch.testUrl),
      'delayTimeoutMs': appSetting.delayTestTimeout,
      'taskPoolSize': maxConcurrentDelayTests,
    };
  }

  Future<void> _toggle(bool value) async {
    await latencyDiagnosticsStore.setEnabled(value);
    if (value) {
      await latencyDiagnosticsStore.recordConfigSnapshot(_configSummary());
    }
    await _load();
  }

  String _timeText(Object? raw) {
    final parsed = raw is String ? DateTime.tryParse(raw) : null;
    if (parsed == null) {
      return '';
    }
    final local = parsed.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }

  String _hysteriaSummary() {
    final counts = <String, int>{};
    for (final record in _records) {
      if (record['type'] != 'round') {
        continue;
      }
      final protocol = record['protocol'];
      if (protocol is! String || protocol.toLowerCase() != 'hysteria2') {
        continue;
      }
      if (record['status'] == 'ok') {
        continue;
      }
      final category = record['category'];
      final key = category is String ? category : latencyErrorUnknown;
      counts[key] = (counts[key] ?? 0) + 1;
    }
    if (counts.isEmpty) {
      return '';
    }
    return counts.entries
        .map((entry) => '${entry.key} ${entry.value}')
        .join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    final hysteriaSummary = _hysteriaSummary();
    return BaseScaffold(
      title: appLocalizations.latencyDiagnostics,
      body: ListView(
        padding: EdgeInsets.only(
          top: context.appBarInset,
          bottom: 32 + context.bottomInset,
          left: 16,
          right: 16,
        ),
        children: [
          generateSection(
            items: [
              ListItem(
                title: Text(appLocalizations.latencyDiagnostics),
                subtitle: Text(appLocalizations.latencyDiagnosticsDesc),
                trailing: CommonSwitch(
                  value: _enabled,
                  onChanged: (value) {
                    _toggle(value);
                  },
                ),
              ),
              ListItem(
                title: Text(appLocalizations.latencyDiagnosticsLogPath),
                subtitle: Text(
                  _logPath.isEmpty
                      ? appLocalizations.latencyDiagnosticsNoRecords
                      : _logPath,
                ),
                trailing: TextButton(
                  onPressed: _logPath.isEmpty
                      ? null
                      : () async {
                          await Clipboard.setData(
                            ClipboardData(text: _logPath),
                          );
                          if (context.mounted) {
                            context.showNotifier(_logPath);
                          }
                        },
                  child: Text(appLocalizations.latencyDiagnosticsCopyPath),
                ),
              ),
              ListItem(
                title: Text(appLocalizations.latencyDiagnosticsHysteriaSummary),
                subtitle: Text(
                  hysteriaSummary.isEmpty
                      ? appLocalizations.latencyDiagnosticsNoRecords
                      : hysteriaSummary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_records.isEmpty)
            Text(
              appLocalizations.latencyDiagnosticsNoRecords,
              style: AppTextStyle.subheadline.of(context),
              textAlign: TextAlign.center,
            )
          else
            generateSection(
              items: [
                for (final record in _records.where(
                  (record) => record['type'] == 'round',
                ))
                  ListItem(
                    title: Text(
                      '${_timeText(record['time'])} '
                      '${record['protocol'] ?? ''}',
                    ),
                    subtitle: Text(
                      '${record['target'] ?? ''} '
                      '${record['status'] ?? ''} '
                      'core ${record['coreDelay'] ?? '-'} ms '
                      '(queue ${record['queueMs'] ?? '-'} ms, '
                      'call ${record['coreMs'] ?? '-'} ms) '
                      '${record['category'] ?? ''}',
                    ),
                  ),
              ],
            ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _load,
            child: Text(appLocalizations.latencyDiagnosticsRefresh),
          ),
        ],
      ),
    );
  }
}
