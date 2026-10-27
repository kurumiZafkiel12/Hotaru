import 'package:flutter_svg/flutter_svg.dart';
import 'package:hotaru/common/flag_emoji.dart';
import 'package:hotaru/ui/shape.dart';
import 'package:hotaru/ui/text_style.dart';
import 'package:material_ui/material_ui.dart';

/// A country flag from the bundled lipis/flag-icons SVG set, named by ISO
/// code. Codes without an SVG (unknown or pseudo codes such as A1) fall
/// back to the emoji flag in the bundled TwEmoji font.
class FlagIcon extends StatelessWidget {
  const FlagIcon({super.key, required this.countryCode, this.width = 36});

  final String? countryCode;
  final double width;

  static String? assetOf(String code) {
    final normalized = switch (code.toUpperCase()) {
      'UK' => 'gb',
      final value => value.toLowerCase(),
    };
    return RegExp(r'^[a-z]{2}$').hasMatch(normalized)
        ? 'assets/images/flags/$normalized.svg'
        : null;
  }

  @override
  Widget build(BuildContext context) {
    final code = countryCode;
    final asset = code == null ? null : assetOf(code);
    final height = width * 0.75;
    if (asset == null) {
      final emoji = (code ?? '').countryFlagEmoji;
      if (emoji.isEmpty || emoji == code) {
        // No flag exists for this code; hold the space, show nothing.
        return SizedBox(width: width, height: height);
      }
      return SizedBox(
        width: width,
        height: height,
        child: Center(
          child: Text(
            emoji,
            style: TextStyle(
              fontFamily: FontFamily.twEmoji.value,
              fontSize: width * 0.66,
              height: 1,
            ),
          ),
        ),
      );
    }
    return ClipRSuperellipse(
      borderRadius: AppRadius.all(4),
      child: SvgPicture.asset(
        asset,
        width: width,
        height: height,
        fit: BoxFit.cover,
        placeholderBuilder: (_) => SizedBox(width: width, height: height),
      ),
    );
  }
}
