import 'package:hotaru/common/common.dart';
import 'package:hotaru/common/media_unlock_checker.dart';
import 'package:hotaru/models/media_unlock.dart';
import 'package:hotaru/ui/icons/icons.dart';
import 'package:hotaru/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';

const _services = [
  MediaPlatform.grok,
  MediaPlatform.openrouter,
  MediaPlatform.poe,
  MediaPlatform.suno,
  MediaPlatform.perplexity,
  MediaPlatform.youtubemusic,
  MediaPlatform.iqiyi,
  MediaPlatform.crunchyroll,
  MediaPlatform.tencent,
  MediaPlatform.alibaba,
  MediaPlatform.netease,
  MediaPlatform.douyin,
  MediaPlatform.cloudflarecn,
  MediaPlatform.reddit,
  MediaPlatform.x,
  MediaPlatform.v2ex,
  MediaPlatform.medium,
  MediaPlatform.stackoverflow,
  MediaPlatform.quora,
  MediaPlatform.telegram,
  MediaPlatform.wikipedia,
  MediaPlatform.apple,
  MediaPlatform.onetrust,
  MediaPlatform.gitlab,
  MediaPlatform.npm,
  MediaPlatform.cdnjs,
  MediaPlatform.unpkg,
  MediaPlatform.nodejs,
  MediaPlatform.steam,
  MediaPlatform.epic,
  MediaPlatform.ubisoft,
  MediaPlatform.humblebundle,
  MediaPlatform.coinbase,
  MediaPlatform.okx,
  MediaPlatform.kraken,
  MediaPlatform.cryptocom,
  MediaPlatform.phantom,
  MediaPlatform.paypal,
  MediaPlatform.mytvsuper,
  MediaPlatform.viutv,
  MediaPlatform.hoytv,
  MediaPlatform.rthk,
];

class MediaAvailabilityView extends StatefulWidget {
  const MediaAvailabilityView({super.key, this.checker});

  final MediaUnlockChecker? checker;

  @override
  State<MediaAvailabilityView> createState() => _MediaAvailabilityViewState();
}

class _MediaAvailabilityViewState extends State<MediaAvailabilityView> {
  late final _checker = widget.checker ?? MediaUnlockChecker();
  final _selected = <MediaPlatform>{};
  final _results = <MediaPlatform, MediaUnlockResult>{};
  bool _busy = false;
  String _error = '';
  int _serial = 0;

  @override
  void dispose() {
    _serial++;
    _checker.cancel();
    super.dispose();
  }

  void _stop() {
    _serial++;
    _checker.cancel();
    setState(() => _busy = false);
  }

  Future<void> _run() async {
    if (_busy || _selected.isEmpty) return;
    final serial = ++_serial;
    setState(() {
      _busy = true;
      _error = '';
      _results.clear();
    });
    try {
      await _checker.checkAll(
        platforms: _selected.toList(),
        onProgress: (result) {
          if (mounted && serial == _serial) {
            setState(() => _results[result.platform] = result);
          }
        },
      );
    } catch (error) {
      if (mounted && serial == _serial) {
        setState(() => _error = compactError(error));
      }
    } finally {
      if (mounted && serial == _serial) setState(() => _busy = false);
    }
  }

  String _label(MediaUnlockResult result) {
    final l = context.appLocalizations;
    final status = switch (result.status) {
      MediaUnlockStatus.unlocked => l.availabilityUnlocked,
      MediaUnlockStatus.limited ||
      MediaUnlockStatus.flagged => l.availabilityLimited,
      MediaUnlockStatus.blocked => l.availabilityBlocked,
      MediaUnlockStatus.failed => l.diagnosticFailed,
      _ => l.availabilityUnknown,
    };
    return [
      status,
      if (result.region?.isNotEmpty ?? false) result.region!,
      if (result.latency != null) '${result.latency} ms',
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final l = context.appLocalizations;
    return CommonScaffold(
      title: l.additionalServices,
      body: ListView(
        padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + context.bottomInset),
        children: [
          Text(l.mediaAvailabilityDesc),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            children: [
              FilledButton(
                onPressed: _busy || _selected.isEmpty ? null : _run,
                child: Text(l.diagnosticRun),
              ),
              TextButton(
                onPressed: _busy ? _stop : null,
                child: Text(l.diagnosticStop),
              ),
            ],
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_error.isNotEmpty) SelectableText(_error),
          for (final platform in _services)
            CheckboxListTile(
              value: _selected.contains(platform),
              onChanged: _busy
                  ? null
                  : (value) => setState(() {
                      if (value ?? false) {
                        _selected.add(platform);
                      } else {
                        _selected.remove(platform);
                      }
                    }),
              title: Text(platform.name),
              subtitle: _results.containsKey(platform)
                  ? Text(_label(_results[platform]!))
                  : null,
              secondary: const GlyphIcon(AppGlyphs.target),
            ),
        ],
      ),
    );
  }
}
