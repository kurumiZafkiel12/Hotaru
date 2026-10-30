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
                    _NodeSpeedTest(proxyName: proxy.name),
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
                  _NodeSpeedTest(proxyName: proxy.name),
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
  const _NodeSpeedTest({required this.proxyName});
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
  List<String> _chain = const [];
  SpeedTestRunner? _runner;
  late final RouteTracker _routeTracker;
  int? _runEpoch;
  int? _runVersion;
  bool _routeChanged = false;
  bool _watchingRoute = false;
  bool _cancelRequested = false;

  @override
  void initState() {
    super.initState();
    _routeTracker = ref.read(routeTrackerProvider.notifier);
    ref.listenManual(routeTrackerProvider, (before, after) {
      if (_running &&
          ((!after.proxied) ||
              (_runEpoch != null &&
                  after.synced &&
                  after.coreEpoch != _runEpoch) ||
              (_runVersion != null &&
                  after.synced &&
                  after.routeVersion > _runVersion!) ||
              (before != null &&
                  before.synced &&
                  after.synced &&
                  before.hostEpoch != after.hostEpoch))) {
        _routeChanged = true;
        _cancelRequested = true;
        _runner?.cancel();
      }
    });
  }

  @override
  void dispose() {
    _cancelRequested = true;
    _runner?.cancel();
    _releaseRoute();
    super.dispose();
  }

  void _releaseRoute() {
    if (_watchingRoute) {
      _watchingRoute = false;
      _routeTracker.detach();
    }
  }

  String _speedText(double? bps) {
    if (bps == null) {
      return context.appLocalizations.unknown;
    }
    return '${formatSpeedValue(bps)} ${formatSpeedUnit(bps)}';
  }

  Future<void> _toggle() async {
    if (_running) {
      _cancelRequested = true;
      _runner?.cancel();
      return;
    }
    final token = NodeSpeedTestGate.tryAcquire();
    if (token == null) {
      setState(() {
        _error = context.appLocalizations.speedTestBusy;
      });
      return;
    }
    final failedText = context.appLocalizations.changeProxyFailedTip;
    setState(() {
      _running = true;
      _error = null;
      _downloadBps = null;
      _liveBps = 0;
      _chain = const [];
      _routeChanged = false;
      _cancelRequested = false;
    });
    try {
      _watchingRoute = true;
      _routeTracker.attach();
      final startRoute = ref.read(routeTrackerProvider);
      final core = ref.read(coreHandlerProvider);
      final proxiesData = await core.getProxies();
      if (!mounted || _cancelRequested) return;
      final chain = resolveProxyChain(proxiesData.proxies, widget.proxyName);
      final result = await core.changeProxy(
        ChangeProxyParams(
          groupName: '',
          proxyName: chain.last,
          forSpeedTest: true,
        ),
      );
      if (result.message.isNotEmpty || result.speedTestProxy.isEmpty) {
        if (mounted) {
          setState(() {
            _error = failedText;
          });
        }
        return;
      }
      if (!mounted || _cancelRequested) {
        if (mounted && _routeChanged) {
          setState(() => _error = context.appLocalizations.auditStale);
        }
        return;
      }
      final currentRoute = ref.read(routeTrackerProvider);
      if (!currentRoute.proxied ||
          (startRoute.synced &&
              currentRoute.hostEpoch != startRoute.hostEpoch) ||
          (currentRoute.synced && currentRoute.coreEpoch != result.coreEpoch) ||
          (currentRoute.synced &&
              currentRoute.routeVersion > result.routeVersion)) {
        setState(() => _error = context.appLocalizations.auditStale);
        return;
      }
      setState(() {
        _chain = chain;
      });
      _runEpoch = result.coreEpoch;
      _runVersion = result.routeVersion;
      final runner = SpeedTestRunner(findProxy: (_) => result.speedTestProxy);
      _runner = runner;
      final testResult = await runner.run(
        provider: SpeedTestProvider.apple,
        durationSeconds: _testDurationSeconds,
        downloadOnly: true,
        onProgress: (phase, liveBps, progress) {
          if (!mounted ||
              !NodeSpeedTestGate.isActive(token) ||
              phase != SpeedTestPhase.download) {
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
        if (testResult.cancelled) {
          _error = _routeChanged ? context.appLocalizations.auditStale : null;
        } else if (testResult.error != null) {
          _error = testResult.error;
        } else {
          _downloadBps = testResult.downloadBps;
        }
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = failedText;
        });
      }
    } finally {
      NodeSpeedTestGate.release(token);
      _runner = null;
      _runEpoch = null;
      _runVersion = null;
      _releaseRoute();
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
    var text = _error != null
        ? _error!
        : _running
        ? _speedText(_liveBps)
        : _speedText(_downloadBps);
    if (_error == null &&
        !_running &&
        _downloadBps != null &&
        _chain.length > 1) {
      text = '$text → ${_chain.last}';
    }
    final tooltip = _chain.length > 1
        ? '${context.appLocalizations.speedTest}: ${_chain.join(' → ')}'
        : context.appLocalizations.speedTest;
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
        message: tooltip,
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
