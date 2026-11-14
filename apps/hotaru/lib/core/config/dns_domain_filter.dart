import 'dns.dart';
import 'geodata.dart';
import 'rule_set.dart';

List<CoreGeoRequest>? dnsFilterGeoRequests(String value) {
  if (!value.toLowerCase().startsWith('geosite:')) return null;
  final selectors = value.substring(8).split(',');
  final requests = <CoreGeoRequest>[];
  for (final selector in selectors) {
    final request = CoreGeoRequest.parse(CoreGeoKind.site, selector);
    if (request == null) throw const FormatException();
    requests.add(request);
  }
  return requests;
}

List<CoreDnsDomainFilter> readDnsDomainFilter(
  String value,
  Map<String, CoreGeoMatchData> geodata,
) {
  final requests = dnsFilterGeoRequests(value);
  if (requests != null) {
    return [
      for (final request in requests)
        if (geodata[request.key] case final data?)
          CoreDnsDomainFilter(data.set, invert: data.inverted)
        else
          throw const FormatException('geo_data_required'),
    ];
  }
  final domain = value.toLowerCase();
  final parts = domain.split('.');
  if (domain.isEmpty ||
      domain.length > 255 ||
      domain.contains(RegExp(r'[\s\x00:/$^\\]')) ||
      parts.last.isEmpty ||
      parts.skip(1).any((part) => part.isEmpty) ||
      parts.indexed.any(
        (entry) =>
            entry.$2.contains('+') && (entry.$1 != 0 || entry.$2 != '+') ||
            entry.$2.contains('*') && entry.$2 != '*',
      ) ||
      parts.length == 1 && parts.first == '+') {
    throw const FormatException();
  }
  final suffix = parts.first == '+' || parts.first.isEmpty;
  final tail = suffix ? parts.skip(1) : parts;
  final escaped = tail
      .map((part) => part == '*' ? r'[^.]+' : RegExp.escape(part))
      .join(r'\.');
  final regex =
      '${switch (parts.first) {
        '+' => r'^(?:[^.]+\.)*',
        '' => r'^(?:[^.]+\.)+',
        _ => '^',
      }}$escaped\$';
  return [
    CoreDnsDomainFilter(
      CoreRuleSetSpec(
        tag: 'dns-filter',
        kind: CoreRuleSetKind.domain,
        domains: !suffix && !parts.contains('*') ? [domain] : const [],
        regexes: suffix || parts.contains('*') ? [regex] : const [],
      ),
    ),
  ];
}
