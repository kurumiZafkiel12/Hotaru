enum CoreRuleSetKind { domain, ipCidr, mixed }

final class CoreRuleSetSpec {
  static const maxEntries = 1000000;
  final String tag;
  final CoreRuleSetKind kind;
  final List<String> domains;
  final List<String> suffixes;
  final List<String> keywords;
  final List<String> regexes;
  final List<String> prefixes;

  CoreRuleSetSpec({
    required this.tag,
    required this.kind,
    List<String> domains = const [],
    List<String> suffixes = const [],
    List<String> keywords = const [],
    List<String> regexes = const [],
    List<String> prefixes = const [],
  }) : domains = List.unmodifiable(domains),
       suffixes = List.unmodifiable(suffixes),
       keywords = List.unmodifiable(keywords),
       regexes = List.unmodifiable(regexes),
       prefixes = List.unmodifiable(prefixes);

  bool get requiresAddress => kind != CoreRuleSetKind.domain;
  bool get isEmpty =>
      domains.isEmpty &&
      suffixes.isEmpty &&
      keywords.isEmpty &&
      regexes.isEmpty &&
      prefixes.isEmpty;
}
