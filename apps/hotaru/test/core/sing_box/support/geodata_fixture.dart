import 'dart:convert';
import 'dart:typed_data';

List<int> geoVarint(int value) {
  final result = <int>[];
  while (value >= 128) {
    result.add((value & 127) | 128);
    value >>= 7;
  }
  return [...result, value];
}

List<int> geoNumber(int field, int value) => [
  ...geoVarint(field << 3),
  ...geoVarint(value),
];
List<int> geoBytes(int field, List<int> value) => [
  ...geoVarint((field << 3) | 2),
  ...geoVarint(value.length),
  ...value,
];
List<int> geoString(int field, String value) =>
    geoBytes(field, utf8.encode(value));

Uint8List geoDatabase(
  String country,
  List<List<int>> entries, {
  bool reverse = false,
}) => Uint8List.fromList(
  geoBytes(1, [
    ...geoString(1, country),
    for (final entry in entries) ...geoBytes(2, entry),
    if (reverse) ...geoNumber(3, 1),
  ]),
);

List<int> geoDomain(
  int type,
  String value, {
  List<String> attributes = const [],
}) => [
  ...geoNumber(1, type),
  ...geoString(2, value),
  for (final attribute in attributes)
    ...geoBytes(3, [...geoString(1, attribute), ...geoNumber(2, 0)]),
];

List<int> geoPrefix(List<int> bytes, int prefix) => [
  ...geoBytes(1, bytes),
  ...geoNumber(2, prefix),
];
