import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/common/browser_leak_result.dart';

void main() {
  test(
    'live page-shaped DNS rows retain resolvers and localize country codes',
    () {
      final result = BrowserLeakResult.fromSnapshot(BrowserLeakKind.dns, {
        'origin': 'https://browserleaks.com',
        'completed': true,
        'resolvers': [
          {
            'ip': '20.168.161.14',
            'organization': 'Microsoft Corporation',
            'country': 'United States, San Jose',
          },
          {
            'ip': '20.168.161.14',
            'organization': 'Microsoft Corporation',
            'country': 'United States, San Jose',
          },
          {'ip': '192.168.1.1', 'organization': 'Local', 'country': ''},
        ],
      });
      expect(result.resolvers, hasLength(1));
      expect(result.resolvers.single.country, 'US');
      expect(result.hasDnsRisk, isFalse);
      expect(result.rtcMatches, isFalse);
    },
  );

  test(
    'domestic ISP evidence remains a risk even if the page is incomplete',
    () {
      final result = BrowserLeakResult.fromSnapshot(BrowserLeakKind.dns, {
        'origin': 'https://browserleaks.com',
        'resolvers': [
          {
            'ip': '114.114.114.114',
            'organization': 'China Telecom',
            'country': 'China, Beijing',
          },
        ],
      });
      expect(result.completed, isFalse);
      expect(result.hasDnsRisk, isTrue);
      expect(result.resolvers.single.country, 'CN');
    },
  );

  BrowserLeakResult rtc({
    String public = '20.189.190.81',
    bool completed = true,
    bool supported = true,
  }) => BrowserLeakResult.fromSnapshot(BrowserLeakKind.webrtc, {
    'origin': 'https://browserleaks.com',
    'completed': completed,
    'fields': {
      'client-ipv4': '20.189.190.81',
      'client-ipv6': '-',
      'rtc-peerconnection': supported ? '✔\nTrue' : '✘\nFalse',
      'rtc-public': public,
      'rtc-local': '192.168.1.2',
    },
  });

  test('WebRTC matching needs a complete, supported, nonempty measurement', () {
    expect(rtc().rtcMatches, isTrue);
    expect(rtc().local, ['192.168.1.2']);
    for (final result in [
      rtc(public: '-'),
      rtc(completed: false),
      rtc(supported: false),
    ]) {
      expect(result.rtcMatches, isFalse);
      expect(result.hasRtcMismatch, isFalse);
    }
  });

  test(
    'only a mismatch with the same IP family establishes address divergence',
    () {
      expect(rtc(public: '1.1.1.1').hasRtcMismatch, isTrue);
      expect(rtc(public: '2606:4700:4700::1111').hasRtcMismatch, isFalse);
      expect(rtc(public: '2606:4700:4700::1111').rtcMatches, isFalse);
    },
  );

  test('unexpected page origin cannot supply diagnostic results', () {
    expect(
      () => BrowserLeakResult.fromSnapshot(BrowserLeakKind.dns, {
        'origin': 'https://example.com',
      }),
      throwsFormatException,
    );
  });
}
