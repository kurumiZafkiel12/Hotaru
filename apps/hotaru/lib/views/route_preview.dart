import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hotaru/common/common.dart';
import 'package:hotaru/core/config/route_preview.dart';
import 'package:hotaru/core/config/profile.dart';
import 'package:hotaru/providers/core.dart';
import 'package:hotaru/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';

class RoutePreviewView extends ConsumerStatefulWidget {
  const RoutePreviewView({super.key});

  @override
  ConsumerState<RoutePreviewView> createState() => _RoutePreviewViewState();
}

class _RoutePreviewViewState extends ConsumerState<RoutePreviewView> {
  final _target = TextEditingController();
  CoreRoutePreview? _result;
  bool _running = false;
  bool _failed = false;
  int _revision = 0;
  String _lastTarget = '';

  @override
  void initState() {
    super.initState();
    _target.addListener(_edited);
  }

  void _edited() {
    if (_lastTarget == _target.text) return;
    _lastTarget = _target.text;
    _revision++;
    setState(() {
      _result = null;
      _failed = false;
      _running = false;
    });
  }

  @override
  void dispose() {
    _revision++;
    _target.dispose();
    super.dispose();
  }

  Future<void> _preview() async {
    if (_running || _target.text.trim().isEmpty) return;
    final revision = ++_revision;
    setState(() {
      _running = true;
      _failed = false;
      _result = null;
    });
    try {
      final result = await ref
          .read(coreHandlerProvider)
          .previewRoute(_target.text.trim());
      if (mounted && revision == _revision) setState(() => _result = result);
    } catch (_) {
      if (mounted && revision == _revision) setState(() => _failed = true);
    } finally {
      if (mounted && revision == _revision) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.appLocalizations;
    final supported = ref.watch(coreHandlerProvider).supportsRoutePreview;
    final result = _result;
    final rule = result?.rule;
    return CommonScaffold(
      title: l10n.routePreviewTitle,
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            l10n.routePreviewScope,
            style: AppTextStyle.footnote.of(context),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _target,
            autocorrect: false,
            onSubmitted: (_) {
              if (supported) _preview();
            },
            decoration: InputDecoration(labelText: l10n.routePreviewTarget),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FilledButton(
              onPressed:
                  supported && !_running && _target.text.trim().isNotEmpty
                  ? _preview
                  : null,
              child: Text(
                _running ? l10n.routePreviewRunning : l10n.routePreviewAction,
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (!supported) Text(l10n.routePreviewUnavailable),
          if (_failed) Text(l10n.routePreviewFailed),
          if (result != null)
            CommonCard(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 12,
                children: [
                  SelectableText(
                    result.target,
                    style: AppTextStyle.headline.of(context),
                  ),
                  Text(switch (result.status) {
                    CoreRoutePreviewStatus.resolved =>
                      l10n.routePreviewResolved,
                    CoreRoutePreviewStatus.addressRequired =>
                      l10n.routePreviewAddressRequired,
                    CoreRoutePreviewStatus.contextRequired =>
                      l10n.routePreviewContextRequired,
                    CoreRoutePreviewStatus.selectionRequired =>
                      l10n.routePreviewSelectionRequired,
                    CoreRoutePreviewStatus.invalidTarget =>
                      l10n.routePreviewInvalidTarget,
                    CoreRoutePreviewStatus.invalidProfile =>
                      l10n.routePreviewFailed,
                  }),
                  if (result.status == CoreRoutePreviewStatus.resolved) ...[
                    Text(
                      l10n.routePreviewRule,
                      style: AppTextStyle.subheadline.of(
                        context,
                        emphasized: true,
                      ),
                    ),
                    SelectableText(
                      rule == null
                          ? l10n.routePreviewDefault
                          : '${result.ruleIndex! + 1} · ${_ruleType(rule.kind)}${rule.value.isEmpty ? '' : ',${rule.value}'}',
                    ),
                    Text(
                      l10n.routePreviewPath,
                      style: AppTextStyle.subheadline.of(
                        context,
                        emphasized: true,
                      ),
                    ),
                    SelectableText(switch (result.action) {
                      CoreRuleAction.reject =>
                        '${l10n.blockConnection} (REJECT)',
                      CoreRuleAction.drop =>
                        '${l10n.blockConnection} (REJECT-DROP)',
                      _ => result.chain.join(' → '),
                    }),
                    if (result.hops.isNotEmpty) ...[
                      Text(
                        l10n.routePreviewHops,
                        style: AppTextStyle.subheadline.of(
                          context,
                          emphasized: true,
                        ),
                      ),
                      SelectableText(result.hops.join(' → ')),
                    ],
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  String _ruleType(CoreRuleKind kind) => switch (kind) {
    CoreRuleKind.domain => 'DOMAIN',
    CoreRuleKind.domainSuffix => 'DOMAIN-SUFFIX',
    CoreRuleKind.domainKeyword => 'DOMAIN-KEYWORD',
    CoreRuleKind.ipCidr => 'IP-CIDR',
    CoreRuleKind.ruleSet => 'RULE-SET',
    CoreRuleKind.always => 'MATCH',
  };
}
