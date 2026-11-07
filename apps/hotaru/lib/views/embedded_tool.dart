import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hotaru/common/common.dart';
import 'package:hotaru/features/browser_diagnostics/tool_browser.dart';
import 'package:hotaru/features/browser_diagnostics/tool_site.dart';
import 'package:hotaru/features/browser_diagnostics/tool_translation.dart';
import 'package:hotaru/providers/providers.dart';
import 'package:hotaru/widgets/widgets.dart';
import 'package:hotaru/ui/icons/icons.dart';

typedef ToolBrowserFactory =
    ToolBrowser Function({
      required ToolSite site,
      required int port,
      required String locale,
      required String translationScript,
      required void Function(int) onProgress,
      required void Function(Uri) onLocation,
      required void Function() onFailure,
    });

class EmbeddedToolView extends ConsumerStatefulWidget {
  final ToolSite site;
  final ToolBrowserFactory? browserFactory;

  const EmbeddedToolView({super.key, required this.site, this.browserFactory});

  @override
  ConsumerState<EmbeddedToolView> createState() => _EmbeddedToolViewState();
}

class _EmbeddedToolViewState extends ConsumerState<EmbeddedToolView> {
  int _reload = 0;

  void _refresh() => setState(() => _reload++);

  Future<void> _setStunBlock(bool enabled) async {
    if (enabled) {
      final agreed = await dialogs.showMessage(
        message: TextSpan(text: context.appLocalizations.webrtcBlockScope),
      );
      if (agreed != true || !mounted) return;
    }
    ref
        .read(patchClashConfigProvider.notifier)
        .update((state) => state.copyWith(blockCommonStun: enabled));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.appLocalizations;
    final site = widget.site;
    final connected = ref.watch(isStartProvider);
    final port = ref.watch(patchClashConfigProvider.select((v) => v.mixedPort));
    final epoch = ref.watch(routeTrackerProvider.select((v) => v.coreEpoch));
    final locale = Localizations.localeOf(context).toLanguageTag();
    return CommonScaffold(
      title: switch (site) {
        ToolSite.dns => l10n.dnsLeakTitle,
        ToolSite.webrtc => l10n.webrtcLeakTitle,
        _ => site.label,
      },
      iconActions: [
        IconButtonData(
          glyph: AppGlyphs.refresh,
          tooltip: l10n.embeddedToolReload,
          onPressed: connected ? _refresh : null,
        ),
      ],
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: [
            Text(
              l10n.embeddedToolScope,
              style: AppTextStyle.footnote.of(context),
            ),
            if (site == ToolSite.webrtc)
              SwitchListTile(
                title: Text(l10n.webrtcBlockAction),
                subtitle: Text(l10n.webrtcBlockScope),
                value: ref.watch(
                  patchClashConfigProvider.select((v) => v.blockCommonStun),
                ),
                onChanged: _setStunBlock,
              ),
            Expanded(
              child: connected
                  ? _ToolBrowserSurface(
                      key: ValueKey((site, port, locale, epoch, _reload)),
                      site: site,
                      port: port,
                      locale: locale,
                      browserFactory: widget.browserFactory,
                      onRetry: _refresh,
                    )
                  : Center(child: Text(l10n.embeddedToolNeedCore)),
            ),
          ],
        ),
      ),
    );
  }
}

class _ToolBrowserSurface extends StatefulWidget {
  final ToolSite site;
  final int port;
  final String locale;
  final ToolBrowserFactory? browserFactory;
  final VoidCallback onRetry;

  const _ToolBrowserSurface({
    super.key,
    required this.site,
    required this.port,
    required this.locale,
    required this.browserFactory,
    required this.onRetry,
  });

  @override
  State<_ToolBrowserSurface> createState() => _ToolBrowserSurfaceState();
}

class _ToolBrowserSurfaceState extends State<_ToolBrowserSurface> {
  ToolBrowser? _browser;
  Timer? _deadline;
  bool _ready = false;
  bool _failed = false;
  int _progress = 0;
  late Uri _location = widget.site.uri;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_browser == null && !_failed) unawaited(_open());
  }

  void _fail() {
    if (!mounted || _failed) return;
    _deadline?.cancel();
    setState(() => _failed = true);
    unawaited(_browser?.close().catchError((Object _) {}) ?? Future.value());
  }

  Future<void> _open() async {
    final l10n = context.appLocalizations;
    final script = toolTranslationScript({
      'DNS Leak Test': l10n.dnsLeakTitle,
      'WebRTC Leak Test': l10n.webrtcLeakTitle,
      'Your Remote IP': l10n.browserRemoteIp,
      'IPv4 Address': l10n.browserIpv4,
      'IPv6 Address': l10n.browserIpv6,
      'Country': l10n.browserCountry,
      'Region': l10n.browserRegion,
      'City': l10n.browserCity,
      'Organization': l10n.browserOrganization,
      'Local IP Address': l10n.browserLocalIp,
      'Public IP Address': l10n.browserPublicIp,
      'WebRTC Support Detection': l10n.browserSupport,
      'No Leak': l10n.browserNoLeak,
      'Leak Detected': l10n.browserLeakDetected,
      'Potential Leak': l10n.browserPotentialLeak,
      'DNS Servers': l10n.browserDnsServers,
      'Session Description': l10n.browserSessionDescription,
      'Media Devices': l10n.browserMediaDevices,
      'Permissions': l10n.browserPermissions,
    }, widget.locale);
    try {
      void progress(int value) {
        if (!mounted || _failed) return;
        if (value >= 100) {
          _deadline?.cancel();
        } else if (_deadline?.isActive != true) {
          _deadline = Timer(const Duration(seconds: 40), _fail);
        }
        setState(() => _progress = value.clamp(0, 100));
      }

      void location(Uri value) {
        if (mounted && !_failed) setState(() => _location = value);
      }

      final factory = widget.browserFactory;
      final browser = _browser = factory != null
          ? factory(
              site: widget.site,
              port: widget.port,
              locale: widget.locale,
              translationScript: script,
              onProgress: progress,
              onLocation: location,
              onFailure: _fail,
            )
          : WindowsToolBrowser(
              site: widget.site,
              port: widget.port,
              locale: widget.locale,
              temporaryPath: Directory.systemTemp.path,
              translationScript: script,
              onProgress: progress,
              onLocation: location,
              onFailure: _fail,
            );
      _deadline = Timer(const Duration(seconds: 40), _fail);
      await browser.initialize();
      if (mounted && !_failed) setState(() => _ready = true);
    } catch (_) {
      _fail();
    }
  }

  @override
  void dispose() {
    _deadline?.cancel();
    unawaited(_browser?.close().catchError((Object _) {}) ?? Future.value());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.appLocalizations;
    if (_failed) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 12,
          children: [
            Text(l10n.embeddedToolUnavailable),
            TonalButton(label: l10n.retry, onPressed: widget.onRetry),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${widget.site.label} · ${_location.host}',
          style: AppTextStyle.caption1.of(context),
        ),
        if (_progress < 100) LinearProgressIndicator(value: _progress / 100),
        Expanded(
          child: _ready
              ? _browser!.build(context)
              : Center(child: Text(l10n.loading)),
        ),
      ],
    );
  }
}
