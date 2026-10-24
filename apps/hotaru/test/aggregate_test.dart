import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/profiles/aggregate.dart';

void main() {
  test('parseAggregateUrls keeps one URL per line and rejects bad lines', () {
    expect(
      parseAggregateUrls(
        'https://a.example/sub\n\n  https://b.example/sub  \n',
      ),
      ['https://a.example/sub', 'https://b.example/sub'],
    );
    expect(
      () => parseAggregateUrls('https://a.example/sub\nnot-a-url'),
      throwsA(isA<FormatException>()),
    );
    expect(() => parseAggregateUrls('   \n'), throwsA(isA<FormatException>()));
    expect(
      () => parseAggregateUrls('ftp://a.example/sub'),
      throwsA(isA<FormatException>()),
    );
  });

  test('merge keeps order, renames collisions, dedupes identical nodes', () {
    final merged = mergeAggregateConfigs([
      (
        label: 'a.example',
        config: {
          'proxies': [
            {'name': 'JP', 'type': 'socks5', 'server': '1.1.1.1', 'port': 1080},
            {'name': 'US', 'type': 'ss', 'server': '2.2.2.2', 'port': 8388},
          ],
        },
      ),
      (
        label: 'b.example',
        config: {
          'proxies': [
            // Same name, different server: kept with a source suffix.
            {'name': 'JP', 'type': 'socks5', 'server': '3.3.3.3', 'port': 1080},
            // Identical to the first JP: dropped, not duplicated.
            {'name': 'JP', 'type': 'socks5', 'server': '1.1.1.1', 'port': 1080},
            {'name': 'JP', 'type': 'ss', 'server': '4.4.4.4', 'port': 8388},
          ],
        },
      ),
      (label: 'c.example', config: {'proxies': []}),
    ]);
    final names = [
      for (final p in merged['proxies'] as List) (p as Map)['name'],
    ];
    expect(names, ['JP', 'US', 'JP（b.example）', 'JP（b.example 2）']);
  });
}
