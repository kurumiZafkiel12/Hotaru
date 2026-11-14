import 'package:flutter_test/flutter_test.dart';
import 'package:hotaru/features/browser_diagnostics/tool_site.dart';

void main() {
  test('browser is bound to one numeric proxy without a direct fallback', () {
    final arguments = toolBrowserArguments(17890, 'zh-CN');
    expect(arguments, contains('--proxy-server=http://127.0.0.1:17890'));
    expect(arguments, contains('--proxy-bypass-list=<-loopback>'));
    expect(arguments, contains('--accept-lang=zh-CN'));
    expect(arguments, isNot(contains('direct://')));
    for (final port in [-1, 0, 65536]) {
      expect(() => toolBrowserArguments(port, 'en'), throwsArgumentError);
    }
    for (final language in ['en --proxy-server=direct://', '', 'en\nUS']) {
      expect(() => toolBrowserArguments(17890, language), throwsArgumentError);
    }
  });

  test(
    'all portals use HTTPS and unsupported navigation stays inside policy',
    () {
      expect(ToolSite.values.where((site) => site.isIpSite).length, 9);
      for (final site in ToolSite.values) {
        expect(ToolSite.allowsNavigation(site.uri), isTrue);
      }
      for (final destination in [
        'file:///private.txt',
        'javascript:alert(1)',
        'http://example.com',
        'intent://example.com',
        'https://user:password@example.com',
      ]) {
        expect(ToolSite.allowsNavigation(Uri.parse(destination)), isFalse);
      }
      expect(ToolSite.allowsNavigation(null), isFalse);
    },
  );
}
