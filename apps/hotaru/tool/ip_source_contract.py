"""Observe approved provider schemas with public resolver IPs, without credentials."""
import concurrent.futures
import datetime
import html.parser
import ipaddress
import json
import pathlib
import re
import sys
import urllib.error
import urllib.request

LIMIT = 1024 * 1024


class ScoreMarkup(html.parser.HTMLParser):
    def __init__(self):
        super().__init__()
        self.elements = []
        self.active = []

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if 'score' in attrs.get('class', '').lower():
            self.active.append([tag, attrs.get('class', ''), ''])

    def handle_data(self, value):
        for item in self.active:
            item[2] = (item[2] + value)[:180]

    def handle_endtag(self, tag):
        for item in self.active[:]:
            if item[0] == tag:
                self.elements.append({'class': item[1], 'text': item[2].strip()})
                self.active.remove(item)


def observe(item):
    provider, ip, address = item
    result = {'provider': provider, 'sample': ip}
    try:
        request = urllib.request.Request(address, headers={
            'User-Agent': 'Hotaru/0.0.7 (+https://github.com/kurumiZafkiel12/Hotaru)',
            'Accept': 'application/json,text/html;q=0.8',
        })
        with urllib.request.urlopen(request, timeout=20) as response:
            raw = response.read(LIMIT + 1)
            if len(raw) > LIMIT:
                raise ValueError('response exceeds observation budget')
            result.update(status=response.status, bytes=len(raw), endpoint=response.url)
        text = raw.decode('utf-8')
        if provider == 'Scamalytics':
            markup = ScoreMarkup()
            markup.feed(text)
            result['score_elements'] = markup.elements[:12]
            result['sample_in_document'] = ip in text
            result['title'] = re.findall(r'<title>([^<]{1,180})</title>', text, re.I)[:1]
        else:
            data = json.loads(text)
            if provider == 'iplocate':
                result['keys'] = sorted(data)
                result['fields'] = {k: data.get(k) for k in [
                    'ip', 'country_code', 'country', 'company', 'privacy', 'asn', 'network',
                ] if k in data}
                result['queried_ip_matches'] = ipaddress.ip_address(data['ip']) == ipaddress.ip_address(ip)
            else:
                result['fields'] = {k: data.get(k) for k in [
                    'objectClassName', 'country', 'startAddress', 'endAddress', 'ipVersion',
                ] if k in data}
    except urllib.error.HTTPError as error:
        result.update(status='http-error', code=error.code)
    except Exception as error:
        result.update(status='unavailable', error_type=type(error).__name__)
    return result


def main():
    probes = []
    for ip in ['8.8.8.8', '2001:4860:4860::8888']:
        probes.extend([
            ('iplocate', ip, f'https://iplocate.io/api/lookup/{ip}'),
            ('RDAP', ip, f'https://rdap.org/ip/{ip}'),
            ('Scamalytics', ip, f'https://scamalytics.com/ip/{ip}'),
        ])
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        observations = list(pool.map(observe, probes))
    document = {
        'checked_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'scope': 'Public resolver samples from the CI network; schema observations only, not Hotaru route or release acceptance',
        'observations': observations,
    }
    pathlib.Path(sys.argv[1]).write_text(json.dumps(document, ensure_ascii=False, indent=2) + '\n')
    for observation in observations:
        message = json.dumps(observation, ensure_ascii=False).replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')
        print(f'::notice title=IP source observation::{message}')


if __name__ == '__main__':
    main()
