/// The emoji flag for an ISO country code, kept in a leaf file with
/// no imports so lib/ui can use it without pulling in the app.
extension FlagEmojiExtension on String {
  String get countryFlagEmoji {
    final code = toUpperCase();
    if (!RegExp(r'^[A-Z]{2}$').hasMatch(code)) {
      return this;
    }
    const regionalIndicatorA = 0x1F1E6;
    return String.fromCharCodes([
      code.codeUnitAt(0) - 0x41 + regionalIndicatorA,
      code.codeUnitAt(1) - 0x41 + regionalIndicatorA,
    ]);
  }
}
