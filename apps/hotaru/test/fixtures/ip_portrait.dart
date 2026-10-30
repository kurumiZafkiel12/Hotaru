import 'package:hotaru/common/ip_portrait.dart';

Map<String, dynamic> profileJson(
  IpPortraitSource source, {
  String ip = '8.8.8.8',
  String country = 'US',
}) => switch (source) {
  IpPortraitSource.ipQuery => {
    'ip': ip,
    'location': {'country_code': country, 'city': 'Mountain View'},
    'isp': {'org': 'Example network', 'asn': 'AS15169'},
    'risk': {'is_vpn': false, 'is_proxy': false, 'risk_score': 0},
  },
  IpPortraitSource.ipApiIs => {
    'ip': ip,
    'location': {'country_code': country},
    'asn': {'asn': 15169, 'org': 'Example network'},
    'company': {'type': 'isp', 'abuser_score': '0.001 (Low)'},
    'is_vpn': true,
  },
  IpPortraitSource.geoJs => {
    'ip': ip,
    'country_code': country,
    'city': 'Mountain View',
    'asn': 15169,
  },
};
