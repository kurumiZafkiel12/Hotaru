import 'package:hotaru/common/common.dart';
import 'package:hotaru/enum/enum.dart';
import 'package:hotaru/models/models.dart';
import 'package:hotaru/providers/providers.dart';
import 'package:hotaru/state.dart';
import 'package:hotaru/ui/icons/icons.dart';
import 'package:hotaru/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void selectGroupProxy(
  WidgetRef ref, {
  required String groupName,
  required GroupType groupType,
  required String proxyName,
}) {
  final isComputedSelected = groupType.isComputedSelected;
  if (isComputedSelected || groupType == GroupType.Selector) {
    final currentProxyName = ref.read(proxyNameProvider(groupName));
    final nextProxyName = switch (isComputedSelected) {
      true => currentProxyName == proxyName ? '' : proxyName,
      false => proxyName,
    };
    ref
        .read(proxiesActionProvider.notifier)
        .changeProxyDebounce(groupName, nextProxyName);
    return;
  }
  dialogs.showNotifier(
    currentAppLocalizations.notSelectedTip,
    level: MessageLevel.warning,
  );
}

/// Built-ins and groups have no definition, and a custom profile's own proxies
/// are the local proxies already.
bool _isAddableToLocal(Proxy proxy, {required bool isCustomProfile}) {
  return (proxy.providerName != null || !isCustomProfile) &&
      !reservedCustomProxyNames.contains(proxy.name) &&
      GroupTypeExtension.getGroupType(proxy.type) == null;
}

class ProxyCard extends ConsumerWidget {
  final String groupName;
  final Proxy proxy;
  final GroupType groupType;
  final ProxyCardType type;
  final String? testUrl;

  const ProxyCard({
    super.key,
    required this.groupName,
    required this.testUrl,
    required this.proxy,
    required this.groupType,
    required this.type,
  });

  Measure get measure => globalState.measure;

  Widget _buildProxyNameText(BuildContext context) {
    if (type == ProxyCardType.compact) {
      return SizedBox(
        height: measure.textHeight(AppTextStyle.subheadline) * 1,
        child: EmojiText(
          proxy.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppTextStyle.subheadline.of(context),
        ),
      );
    } else {
      return SizedBox(
        height: measure.textHeight(AppTextStyle.subheadline) * 2,
        child: EmojiText(
          proxy.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: AppTextStyle.subheadline.of(context),
        ),
      );
    }
  }

  void _handleSelect(WidgetRef ref) {
    selectGroupProxy(
      ref,
      groupName: groupName,
      groupType: groupType,
      proxyName: proxy.name,
    );
  }

  void _handleAddToLocalProxies(WidgetRef ref) {
    final proxiesAction = ref.read(proxiesActionProvider.notifier);
    globalState.safeRun(() => proxiesAction.addToLocalProxies(proxy.name));
  }

  List<CommonPopupMenuItem> _menuItems(
    BuildContext context,
    WidgetRef ref, {
    required bool inUse,
    required bool pinned,
    required bool addable,
  }) {
    final appLocalizations = context.appLocalizations;
    return [
      if (groupType == GroupType.Selector)
        CommonPopupMenuItem(
          glyph: AppGlyphs.checkCircle,
          label: appLocalizations.select,
          checked: inUse,
          onPressed: () => _handleSelect(ref),
        )
      else if (groupType.isComputedSelected)
        CommonPopupMenuItem(
          glyph: AppGlyphs.pin,
          label: appLocalizations.preferred,
          checked: pinned,
          onPressed: () => _handleSelect(ref),
        ),
      if (addable)
        CommonPopupMenuItem(
          glyph: AppGlyphs.listAdd,
          label: appLocalizations.addToLocalProxies,
          onPressed: () => _handleAddToLocalProxies(ref),
        ),
    ];
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final measure = globalState.measure;
    final isLoose = type == ProxyCardType.loose;
    final delayText = _DelayText(
      proxy: proxy,
      testUrl: testUrl,
      alignment: isLoose ? Alignment.centerLeft : Alignment.centerRight,
    );
    final proxyNameText = _buildProxyNameText(context);
    final typeStyle = AppTextStyle.footnote
        .of(context)
        .copyWith(
          overflow: TextOverflow.ellipsis,
          color: context.colorScheme.onSurface.opacity80,
        );
    final details = isLoose
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: measure.textHeight(AppTextStyle.footnote),
                child: _ProxyDesc(proxy: proxy, style: typeStyle),
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 8,
                children: [
                  delayText,
                  if (groupType == GroupType.Selector)
                    _NodeSpeedTest(groupName: groupName, proxyName: proxy.name),
                ],
              ),
            ],
          )
        : SizedBox(
            height: measure.textHeight(AppTextStyle.footnote),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Flexible(
                  flex: 1,
                  child: TooltipText(
                    text: Text(proxy.type, maxLines: 1, style: typeStyle),
                  ),
                ),
                delayText,
                if (groupType == GroupType.Selector)
                  _NodeSpeedTest(groupName: groupName, proxyName: proxy.name),
              ],
            ),
          );
    return Consumer(
      builder: (context, ref, _) {
        final inUse = ref.watch(
          selectedProxyNameProvider(
            groupName,
          ).select((name) => name == proxy.name),
        );
        final pinned =
            groupType.isComputedSelected &&
            ref.watch(
              proxyNameProvider(groupName).select((name) => name == proxy.name),
            );
        final isCustomProfile = ref.watch(
          currentProfileProvider.select(
            (profile) => profile?.type == ProfileType.custom,
          ),
        );
        return ContextMenuRegion(
          menuItems: _menuItems(
            context,
            ref,
            inUse: inUse,
            pinned: pinned,
            addable: _isAddableToLocal(proxy, isCustomProfile: isCustomProfile),
          ),
          child: CommonCard(
            radius: AppCorner.lg,
            enterActionsOnRight: true,
            key: key,
            onPressed: () => _handleSelect(ref),
            isSelected: inUse,
            child: Container(
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 4,
                    children: [
                      Expanded(child: proxyNameText),
                      if (pinned)
                        SelectionBadge.preferred(inUse: inUse)
                      else if (inUse)
                        const SelectionBadge(),
                    ],
                  ),
                  const SizedBox(height: 8),
                  details,
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ProxyDesc extends ConsumerWidget {
  const _ProxyDesc({required this.proxy, required this.style});

  final Proxy proxy;
  final TextStyle style;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isGroup = GroupType.values.any((type) => type.name == proxy.type);
    final nodeName = isGroup
        ? ref.watch(
            realSelectedProxyStateProvider(
              proxy.name,
            ).select((state) => state.proxyName),
          )
        : proxy.name;
    return EmojiText(
      nodeName == proxy.name ? proxy.type : '${proxy.type}($nodeName)',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: style,
    );
  }
}

class _DelayText extends ConsumerStatefulWidget {
  const _DelayText({
    required this.proxy,
    required this.testUrl,
    required this.alignment,
  });

  final Proxy proxy;
  final String? testUrl;
  final Alignment alignment;

  @override
  ConsumerState<_DelayText> createState() => _DelayTextState();
}

class _DelayTextState extends ConsumerState<_DelayText> {
  final FocusNode _focusNode = SkipTraversalFocusNode();
  bool _isFocused = false;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_handleFocusChange);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocusChange);
    _focusNode.dispose();
    super.dispose();
  }

  void _handleFocusChange() {
    final isFocused = _focusNode.hasPrimaryFocus;
    if (isFocused == _isFocused) {
      return;
    }
    setState(() {
      _isFocused = isFocused;
    });
  }

  void _handleTestCurrentDelay() {
    ref
        .read(proxiesActionProvider.notifier)
        .proxyDelayTest(widget.proxy, widget.testUrl);
  }

  Widget _withFocusRing(BuildContext context, Widget child) {
    if (!_isFocused) {
      return child;
    }
    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        Positioned(
          top: -2,
          right: -3,
          bottom: -2,
          left: -3,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: ShapeDecoration(
                shape: AppShape.xs.copyWith(
                  side: focusRingSide(context.colorScheme),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final measure = globalState.measure;
    final delay = ref.watch(
      delayProvider(proxyName: widget.proxy.name, testUrl: widget.testUrl),
    );
    final phase = ref.watch(
      delayTestPhaseProvider(
        proxyName: widget.proxy.name,
        testUrl: widget.testUrl,
      ),
    );
    return Actions(
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            _handleTestCurrentDelay();
            return null;
          },
        ),
      },
      child: Focus(
        focusNode: _focusNode,
        child: SizedBox(
          height: measure.textHeight(AppTextStyle.caption2),
          child: FadeBox(
            alignment: widget.alignment,
            child: phase != null || delay == null
                ? SizedBox(
                    height: measure.textHeight(AppTextStyle.caption2),
                    width: measure.textHeight(AppTextStyle.caption2),
                    child: _withFocusRing(context, switch (phase) {
                      DelayTestPhase.running => CommonCircleLoading(
                        size: measure.textHeight(AppTextStyle.caption2),
                      ),
                      DelayTestPhase.queued => GlyphIcon(
                        AppGlyphs.clock,
                        size: measure.textHeight(AppTextStyle.caption2),
                        color: context.colorScheme.onSurfaceVariant.opacity38,
                      ),
                      null => Tooltip(
                        message: context.appLocalizations.delayTest,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _handleTestCurrentDelay,
                          child: GlyphIcon(
                            AppGlyphs.bolt,
                            size: measure.textHeight(AppTextStyle.caption2),
                          ),
                        ),
                      ),
                    }),
                  )
                : GestureDetector(
                    onTap: _handleTestCurrentDelay,
                    child: _withFocusRing(
                      context,
                      Text(
                        delay > 0
                            ? '$delay ms'
                            : delayFailureText(delay, context.appLocalizations),
                        maxLines: 1,
                        style: AppTextStyle.caption2
                            .of(context, emphasized: true)
                            .copyWith(
                              overflow: TextOverflow.ellipsis,
                              color: context.colorScheme.delayColor(delay),
                            ),
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

class _NodeSpeedTest extends ConsumerStatefulWidget {
  const _NodeSpeedTest({required this.groupName, required this.proxyName});

  final String groupName;
  final String proxyName;

  @override
  ConsumerState<_NodeSpeedTest> createState() => _NodeSpeedTestState();
}

class _NodeSpeedTestState extends ConsumerState<_NodeSpeedTest> {
  static const _testDurationSeconds = 10;

  bool _running = false;
  double? _downloadBps;
  double _liveBps = 0;
  String? _error;
  SpeedTestRunner? _runner;

  @override
  void dispose() {
    _runner?.cancel();
    super.dispose();
  }

  String _speedText(double? bps) {
    if (bps == null) {
      return context.appLocalizations.unknown;
    }
    return '${formatSpeedValue(bps)} ${formatSpeedUnit(bps)}';
  }

  Future<void> _toggle() async {
    if (_running) {
      _runner?.cancel();
      return;
    }
    final appLocalizations = context.appLocalizations;
    final switchFailedText = appLocalizations.changeProxyFailedTip;
    final directText = appLocalizations.speedTestDirect;
    final proxiesAction = ref.read(proxiesActionProvider.notifier);
    final originalName = ref.read(proxyNameProvider(widget.groupName));
    final isAlreadySelected = originalName == widget.proxyName;
    setState(() {
      _running = true;
      _error = null;
      _downloadBps = null;
      _liveBps = 0;
    });
    var switched = false;
    try {
      if (!isAlreadySelected) {
        await proxiesAction.changeProxy(
          groupName: widget.groupName,
          proxyName: widget.proxyName,
        );
        proxiesAction.updateGroupsDebounce();
        if (mounted) {
          final selected = ref.read(
            selectedProxyNameProvider(widget.groupName),
          );
          if (selected != widget.proxyName) {
            setState(() {
              _error = switchFailedText;
            });
            return;
          }
        }
        switched = true;
      }
      if (!mounted) {
        return;
      }
      final proxy = HotaruHttpOverrides.findProxyForReader(
        ref.read,
        Uri.parse('https://example.com'),
      );
      if (!proxy.startsWith('PROXY')) {
        setState(() {
          _error = directText;
        });
        return;
      }
      final runner = SpeedTestRunner(findProxy: (_) => proxy);
      _runner = runner;
      final result = await runner.run(
        provider: SpeedTestProvider.apple,
        durationSeconds: _testDurationSeconds,
        downloadOnly: true,
        onProgress: (phase, liveBps, progress) {
          if (!mounted || phase != SpeedTestPhase.download) {
            return;
          }
          setState(() {
            _liveBps = liveBps;
          });
        },
      );
      if (!mounted) {
        return;
      }
      setState(() {
        if (result.cancelled) {
          _error = null;
        } else if (result.error != null) {
          _error = result.error;
        } else {
          _downloadBps = result.downloadBps;
        }
      });
    } finally {
      if (switched &&
          originalName != null &&
          originalName.isNotEmpty &&
          originalName != widget.proxyName) {
        await proxiesAction.changeProxy(
          groupName: widget.groupName,
          proxyName: originalName,
        );
        proxiesAction.updateGroupsDebounce();
      }
      if (mounted) {
        setState(() {
          _running = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final measure = globalState.measure;
    final size = measure.textHeight(AppTextStyle.caption2);
    final text = _error != null
        ? _error!
        : _running
        ? _speedText(_liveBps)
        : _speedText(_downloadBps);
    Widget textWidget = Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: AppTextStyle.caption2
          .of(context, emphasized: true)
          .copyWith(
            color: _error != null ? Theme.of(context).colorScheme.error : null,
          ),
    );
    if (_error != null) {
      textWidget = Tooltip(message: _error, child: textWidget);
    }
    return SizedBox(
      height: size,
      child: Tooltip(
        message: context.appLocalizations.speedTest,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _toggle,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 4,
            children: [
              if (_running)
                CommonCircleLoading(size: size)
              else
                GlyphIcon(AppGlyphs.speed, size: size),
              textWidget,
            ],
          ),
        ),
      ),
    );
  }
}
