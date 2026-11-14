enum ToolSite {
  dns('BrowserLeaks', 'https://browserleaks.com/dns'),
  webrtc('BrowserLeaks', 'https://browserleaks.com/webrtc'),
  ipPure('IPPure', 'https://ippure.com/'),
  ping0('Ping0', 'https://ping0.cc/'),
  ipCheck('IPCheck.ing', 'https://ipcheck.ing/'),
  netCoffee('Net.Coffee', 'https://net.coffee/'),
  scamalytics('Scamalytics', 'https://scamalytics.com/ip'),
  browserLeaksIp('BrowserLeaks', 'https://browserleaks.com/ip'),
  whoer('Whoer', 'https://whoer.net/'),
  ipInfo('IPinfo', 'https://ipinfo.io/'),
  ipLark('IPLark', 'https://iplark.com/');

  const ToolSite(this.label, this.address);
  final String label;
  final String address;

  Uri get uri => Uri.parse(address);
  bool get isIpSite => this != dns && this != webrtc;

  static bool allowsNavigation(Uri? uri) =>
      uri != null &&
      uri.scheme == 'https' &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty;
}

String toolBrowserArguments(int port, String locale) {
  if (port < 1 || port > 65535) throw ArgumentError.value(port, 'port');
  if (!RegExp(r'^[a-z]{2,3}(?:-[A-Za-z]{2,4})?$').hasMatch(locale)) {
    throw ArgumentError.value(locale, 'locale');
  }
  return '--proxy-server=http://127.0.0.1:$port --proxy-bypass-list=<-loopback> --lang=$locale --accept-lang=$locale';
}
