import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/core/sing_box/outbound_ip.dart';
import 'package:hotaru/models/models.dart';

void main() {
  test(
    'only public addresses qualify an IP source, including mapped IPv6',
    () async {
      expect(await mentionsPublicIp('{"ip":"1.1.1.1"}'), isTrue);
      expect(await mentionsPublicIp('::ffff:8.8.8.8'), isTrue);
      for (final body in [
        '<html>captcha</html>',
        '192.168.1.1',
        '100.64.1.1',
        '198.18.0.1',
        '2001:db8::1',
        '203.0.113.1',
      ]) {
        expect(await mentionsPublicIp(body), isFalse, reason: body);
      }
    },
  );

  test(
    'an HTML or private-IP reply cannot win and losing requests are cancelled',
    () async {
      var active = 0;
      var peak = 0;
      var cancellations = 0;
      final result = await lookupSingBoxOutboundIp(
        const OutboundIpParams(
          urls: [
            'https://slow.invalid/',
            'https://captcha.invalid/',
            'https://private.invalid/',
            'https://valid.invalid/',
          ],
          proxyName: 'selected',
          timeout: 5000,
        ),
        (params, cancelled) async {
          active++;
          if (active > peak) peak = active;
          try {
            if (params.url.contains('slow')) {
              await cancelled;
              cancellations++;
            }
            return (
              result: ProbeResult(
                url: params.url,
                statusCode: 200,
                body: Uri.parse(params.url).host == 'valid.invalid'
                    ? '{"ip":"1.1.1.1"}'
                    : params.url.contains('private')
                    ? '192.168.1.1'
                    : '<html>captcha</html>',
                chains: const ['B', 'selected'],
              ),
              snapshot: const RouteSnapshot(coreEpoch: 3, routeVersion: 2),
              hits: const [
                RouteHit(
                  host: 'actual.invalid',
                  proxy: 'selected',
                  exit: 'token',
                ),
              ],
            );
          } finally {
            active--;
          }
        },
      );
      expect(result.url, 'https://valid.invalid/');
      expect(result.coreEpoch, 3);
      expect(result.nodeHits, result.hits);
      expect(result.chains, ['B', 'selected']);
      expect(peak, lessThanOrEqualTo(3));
      expect(cancellations, 1);
      expect(active, 0);
    },
  );

  test('the shared timeout cancels requests before returning', () async {
    var closed = false;
    final result = await lookupSingBoxOutboundIp(
      const OutboundIpParams(urls: ['https://slow.invalid/'], timeout: 20),
      (params, cancelled) async {
        await cancelled;
        closed = true;
        return (
          result: const ProbeResult(error: 'failed'),
          snapshot: const RouteSnapshot(),
          hits: <RouteHit>[],
        );
      },
    );
    expect(result.error, 'timeout');
    expect(closed, isTrue);
  });
}
