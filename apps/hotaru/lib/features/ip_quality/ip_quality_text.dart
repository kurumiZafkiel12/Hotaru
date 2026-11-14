import 'package:hotaru/models/models.dart';
import 'package:hotaru/providers/config.dart';
import 'package:hotaru/providers/ip_quality.dart';
import 'package:hotaru/ui/ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'labels.dart';
import 'facts_labels.dart';
import 'package:hotaru/common/system.dart';
import 'package:hotaru/providers/ip_facts.dart';

class IpQualityText extends ConsumerWidget {
  const IpQualityText({
    super.key,
    required this.ip,
    this.style,
    this.useIpFacts,
  });

  final String ip;
  final TextStyle? style;
  final bool? useIpFacts;

  static const _mask = '*****';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final useFacts = useIpFacts ?? system.isWindows;
    final facts = useFacts ? ref.watch(ipFactsProvider(ip)).value : null;
    final quality = useFacts ? null : ref.watch(ipQualityProvider(ip)).value;
    final hideIp = ref.watch(
      appSettingProvider.select((state) => state.hideIp),
    );
    final shownIp = hideIp ? _mask : ip;
    final color = useFacts
        ? facts?.risk.color(context)
        : quality?.level.color(context);
    var style = this.style;
    if (hideIp) {
      style = (style ?? const TextStyle()).toJetBrainsMono;
    }
    if (color != null) {
      style = (style ?? const TextStyle()).copyWith(color: color);
    }
    return Tooltip(
      preferBelow: false,
      message: shownIp,
      child: Text(
        shownIp,
        style: style,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
