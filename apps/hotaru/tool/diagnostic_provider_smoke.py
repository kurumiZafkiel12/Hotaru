import concurrent.futures
import datetime
import ipaddress
import json
import pathlib
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request


def fetch(url):
    request = urllib.request.Request(url, headers={'User-Agent': 'Hotaru-Diagnostics-Provider-Survey/0.0.5'})
    with urllib.request.urlopen(request, timeout=10) as response:
        body = response.read(262145)
        if len(body) > 262144:
            raise ValueError('provider response too large')
        return body.decode('utf-8')


def geojs():
    data = json.loads(fetch('https://get.geojs.io/v1/ip/geo.json'))
    ipaddress.ip_address(data['ip'])
    latitude, longitude = float(data['latitude']), float(data['longitude'])
    if not (-90 <= latitude <= 90 and -180 <= longitude <= 180):
        raise ValueError('invalid coordinates')
    return {'position_schema': True, 'country_schema': bool(re.fullmatch('[A-Za-z]{2}', data.get('country_code', '')))}


def reputation(source, url):
    body = fetch(url)
    data = json.loads(body)
    if ipaddress.ip_address(data['ip']) != ipaddress.ip_address('8.8.8.8'):
        raise ValueError('queried IP mismatch')
    risk = data.get('risk', {}) if source == 'IPQuery' else data
    return {'queried_ip_matches': True, 'body_bytes': len(body.encode('utf-8')), 'within_app_budget': len(body.encode('utf-8')) <= 16384, 'boolean_risk_fields': sum(isinstance(value, bool) for key, value in risk.items() if key.startswith('is_'))}


def ipify(family):
    url = 'https://api.ipify.org?format=json' if family == 4 else 'https://api6.ipify.org?format=json'
    data = json.loads(fetch(url))
    actual_family = ipaddress.ip_address(data['ip']).version
    if actual_family != family:
        raise ValueError('IP family mismatch')
    return {'expected_family': family, 'response_family': actual_family}


def dns_receipt():
    lease = fetch('https://bash.ws/id').strip()
    if not re.fullmatch('[A-Za-z0-9-]{1,64}', lease):
        raise ValueError('invalid DNS lease')

    def lookup(index):
        try:
            subprocess.run([sys.executable, '-c', 'import socket,sys; socket.getaddrinfo(sys.argv[1],None)', f'{index}.{lease}.bash.ws'], timeout=6, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except subprocess.TimeoutExpired:
            pass

    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        list(pool.map(lookup, range(1, 9)))
    addresses = set()
    for _ in range(3):
        time.sleep(0.4)
        data = json.loads(fetch(f'https://bash.ws/dnsleak/test/{lease}?json=2'))
        if not isinstance(data, list):
            raise ValueError('invalid authority receipt')
        for row in data:
            if isinstance(row, dict) and row.get('type') == 'dns':
                address = ipaddress.ip_address(row['ip'])
                if address.is_global:
                    addresses.add(address)
        if addresses:
            break
    return {'queries': 8, 'resolvers': len(addresses), 'ipv4_resolvers': sum(ip.version == 4 for ip in addresses), 'ipv6_resolvers': sum(ip.version == 6 for ip in addresses)}


def survey(name, probe):
    try:
        evidence = probe()
        status = 'observed' if name != 'bash.ws' or evidence['resolvers'] else 'no-receipt'
        return {'provider': name, 'status': status, **evidence}
    except urllib.error.HTTPError as error:
        return {'provider': name, 'status': 'http-error', 'code': error.code}
    except Exception as error:
        return {'provider': name, 'status': 'unavailable', 'error_type': type(error).__name__}


def main():
    probes = [
        ('GeoJS', geojs),
        ('ipify IPv4', lambda: ipify(4)),
        ('ipify IPv6', lambda: ipify(6)),
        ('IPQuery', lambda: reputation('IPQuery', 'https://api.ipquery.io/8.8.8.8?format=json')),
        ('ipapi.is', lambda: reputation('ipapi.is', 'https://api.ipapi.is/?q=8.8.8.8')),
        ('bash.ws', dns_receipt),
    ]
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(lambda item: survey(*item), probes))
    document = {
        'checked_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'scope': 'CI runner network only; not app routing, browser coverage, safety, unlock or release acceptance',
        'results': results,
    }
    pathlib.Path(sys.argv[1]).write_text(json.dumps(document, indent=2) + '\n')
    for result in results:
        message = json.dumps(result).replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')
        print(f'::notice title=Diagnostic provider survey::{message}')


if __name__ == '__main__':
    main()
