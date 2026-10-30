import 'package:hotaru/common/ice_probe.dart';
import 'package:flutter_test/flutter_test.dart';

IceAddress address(String ip, {String kind = 'srflx'}) =>
    IceAddress(address: ip, port: 3478, kind: kind, protocol: 'udp');

void main() {
  test('ICE candidate parsing preserves types and hides SDP credentials', () {
    final candidate = IceAddress.parse(
      'candidate:1 1 UDP 123 8.8.8.8 3478 typ srflx raddr 192.168.1.1 rport 42 ufrag private-token',
    );
    expect(candidate?.kind, 'srflx');
    expect(candidate?.address, '8.8.8.8');
    expect(candidate?.identity, isNot(contains('private-token')));
    expect(
      IceAddress.parse('candidate:1 1 UDP 1 abc.local 1234 typ host')?.isPublic,
      isFalse,
    );
    for (final raw in [
      'invalid',
      'candidate:1 1 UDP 1 invalid 1234 typ host',
      'candidate:1 1 UDP 1 8.8.8.8 -1 typ host',
    ]) {
      expect(IceAddress.parse(raw), isNull);
    }
  });

  test(
    'disabled, missing, private, relay-only or incomplete ICE never means safe',
    () {
      for (final candidates in <List<IceAddress>>[
        [],
        [address('192.168.1.2', kind: 'host')],
        [address('8.8.8.8', kind: 'relay')],
      ]) {
        expect(
          IceProbeResult(
            candidates: candidates,
            completed: true,
          ).verdict(['8.8.8.8']),
          IceVerdict.inconclusive,
        );
      }
      expect(
        IceProbeResult(
          candidates: [address('8.8.8.8')],
          completed: false,
        ).verdict(['8.8.8.8']),
        IceVerdict.inconclusive,
      );
      expect(
        IceProbeResult(
          candidates: [address('8.8.8.8')],
          completed: true,
        ).verdict([]),
        IceVerdict.inconclusive,
      );
    },
  );

  test(
    'compares IPv4 and IPv6 samples without declaring a country-based verdict',
    () {
      final match = IceProbeResult(
        candidates: [address('8.8.8.8')],
        completed: true,
      );
      expect(match.verdict(['8.8.8.8']), IceVerdict.matching);
      expect(match.verdict(['1.1.1.1']), IceVerdict.risk);
      final dual = IceProbeResult(
        candidates: [address('8.8.8.8'), address('2606:4700:4700::1111')],
        completed: true,
      );
      expect(dual.verdict(['8.8.8.8']), IceVerdict.risk);
      expect(
        dual.verdict(['8.8.8.8', '2606:4700:4700::1111']),
        IceVerdict.matching,
      );
    },
  );
}
