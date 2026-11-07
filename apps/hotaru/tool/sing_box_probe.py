"""Exercise the pinned sing-box clash_api against controlled loopback traffic."""

import argparse
import contextlib
import http.client
import http.server
import json
import os
import pathlib
import queue
import select
import shutil
import socket
import ssl
import subprocess
import tempfile
import threading
import time
import urllib.request
import urllib.error
import urllib.parse
import uuid


def progress(stage):
    print(f'::notice title=Sing-box P0::{stage}', flush=True)


class Origin(http.server.BaseHTTPRequestHandler):
    def do_HEAD(self):
        time.sleep(0.025)
        self.send_response(200)
        self.send_header('Content-Length', '0')
        self.end_headers()

    def do_GET(self):
        if self.path == '/release':
            self.server.release.set()
        body = b'hotaru-sing-box-probe'
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body[:1])
        self.wfile.flush()
        if self.path == '/hold':
            self.server.release.wait(timeout=30)
        self.wfile.write(body[1:])

    def log_message(self, *_):
        pass


class Proxy(Origin):
    def do_CONNECT(self):
        host, destination_port = self.path.rsplit(':', 1)
        allowed = ['127.0.0.1'] + (['198.18.7.2'] if getattr(self.server, 'tun_target', False) else [])
        if host not in allowed or int(destination_port) != self.server.origin_port:
            self.send_error(403)
            return
        with socket.create_connection(('127.0.0.1', int(destination_port)), timeout=3) as upstream:
            self.server.receipts.append(self.path)
            self.send_response(200)
            self.end_headers()
            sockets = [self.connection, upstream]
            while True:
                readable, _, _ = select.select(sockets, [], [], 30)
                if not readable:
                    return
                for source in readable:
                    data = source.recv(65536)
                    if not data:
                        return
                    destination = upstream if source is self.connection else self.connection
                    destination.sendall(data)

    def do_GET(self):
        self.server.receipts.append(self.path)
        super().do_GET()


class FixtureServer(http.server.ThreadingHTTPServer):
    tls = None

    def get_request(self):
        connection, address = super().get_request()
        connection.settimeout(5)
        try:
            if self.tls is not None:
                connection = self.tls.wrap_socket(connection, server_side=True)
            return connection, address
        except BaseException:
            connection.close()
            raise


@contextlib.contextmanager
def server(handler, tls=None):
    instance = FixtureServer(('127.0.0.1', 0), handler)
    instance.receipts = []
    instance.release = threading.Event()
    instance.tls = tls
    thread = threading.Thread(target=instance.serve_forever, daemon=True)
    thread.start()
    try:
        yield instance
    finally:
        instance.release.set()
        instance.shutdown()
        instance.server_close()
        thread.join()


def port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


@contextlib.contextmanager
def fixture_trust(certificate):
    environment = dict(os.environ, SSL_CERT_FILE=str(certificate))
    if os.name != 'nt':
        yield environment
        return
    if os.environ.get('CI') != 'true':
        raise RuntimeError('Windows HTTPS fixture trust is restricted to disposable CI')
    fingerprint = ssl.PEM_cert_to_DER_cert(certificate.read_text(encoding='utf-8'))
    import hashlib

    thumbprint = hashlib.sha1(fingerprint).hexdigest()
    progress('Install disposable CI fixture CA')
    subprocess.run(['certutil', '-f', '-addstore', 'Root', str(certificate)],
                   check=True, stdout=subprocess.DEVNULL, timeout=15)
    try:
        yield environment
    finally:
        progress('Remove disposable CI fixture CA')
        subprocess.run(['certutil', '-delstore', 'Root', thumbprint],
                       check=True, stdout=subprocess.DEVNULL, timeout=15)


def windows_snapshot(name):
    if len(name) != 17 or not name.startswith('HotaruP0-') or any(
            character not in '0123456789abcdef' for character in name[9:]):
        raise RuntimeError('Unexpected fixture interface name')
    script = r"""
$ErrorActionPreference = 'Stop'
$proxy = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$routes = @(Get-NetRoute)
$adapters = @(Get-NetAdapter -IncludeHidden)
$addresses = @(Get-NetIPAddress)
$dns = @{}
Get-DnsClientServerAddress | ForEach-Object {
    $dns["$($_.InterfaceIndex)|$($_.AddressFamily)"] = @($_.ServerAddresses) -join ','
}
$defaults = @(($routes | Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' -or $_.DestinationPrefix -eq '::/0' }) |
    ForEach-Object { "$($_.DestinationPrefix)|$($_.InterfaceIndex)|$($_.NextHop)|$($_.RouteMetric)" } | Sort-Object)
@{
    adapterCount = @($adapters | Where-Object { $_.Name -eq 'INTERFACE_NAME' }).Count
    addressCount = @($addresses | Where-Object { $_.InterfaceAlias -eq 'INTERFACE_NAME' }).Count
    routeCount = @($routes | Where-Object { $_.DestinationPrefix -eq '198.18.7.0/30' }).Count
    defaultRoutes = $defaults
    proxy = @{ enabled = $proxy.ProxyEnable; server = $proxy.ProxyServer; pac = $proxy.AutoConfigURL }
    dns = $dns
} | ConvertTo-Json -Depth 4 -Compress
""".replace('INTERFACE_NAME', name)
    result = subprocess.run(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', script],
                            capture_output=True, text=True, timeout=20, check=True)
    return json.loads(result.stdout)


def wait_tun_cleanup(name, baseline):
    deadline = time.monotonic() + 20
    while True:
        after = windows_snapshot(name)
        if not after['adapterCount'] and not after['addressCount'] and not after['routeCount']:
            break
        if time.monotonic() >= deadline:
            raise RuntimeError('TUN interface, addresses or routes survived stop')
        time.sleep(0.5)
    assert after['proxy'] == baseline['proxy'], 'System proxy changed'
    assert after['defaultRoutes'] == baseline['defaultRoutes'], 'Default routes changed'
    assert all(after['dns'].get(key) == value for key, value in baseline['dns'].items()), 'Existing interface DNS changed'


def host_eof_probe(binary, config, environment, name, baseline, log_path):
    messages = queue.Queue()
    with log_path.open('w+') as log:
        process = subprocess.Popen([binary, 'run', '-c', str(config), '--stdio-control'],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=log, env=environment, text=True)

        def read_events():
            for line in process.stdout:
                messages.put(line)
            messages.put(None)

        reader = threading.Thread(target=read_events, daemon=True)
        reader.start()
        try:
            message = messages.get(timeout=20)
            if message is None:
                raise RuntimeError('Host exited before EOF fixture startup')
            event = json.loads(message)
            assert event['protocol'] == 'hotaru-stdio-v1' and event['pid'] == process.pid
            assert event['event'] == 'ready'
            active = windows_snapshot(name)
            assert active['adapterCount'] == 1 and active['addressCount'] > 0 and active['routeCount'] > 0
            assert process.poll() is None, 'Host exited before parent control pipe closed'
            process.stdin.close()
            assert process.wait(timeout=10) == 0, 'Host failed during EOF cleanup'
            stopped = json.loads(messages.get(timeout=3))
            assert stopped['protocol'] == 'hotaru-stdio-v1' and stopped['pid'] == process.pid
            assert stopped['event'] == 'stopped' and stopped.get('clean') is True
            assert messages.get(timeout=3) is None
            wait_tun_cleanup(name, baseline)
        finally:
            if not process.stdin.closed:
                process.stdin.close()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
            reader.join(timeout=2)
            process.stdout.close()


def owner_loss_probe(dart, environment, name, baseline):
    result = subprocess.run([
        dart, str(pathlib.Path(__file__).with_name('sing_box_owner_loss_smoke.dart')),
    ], env=environment, text=True, capture_output=True, timeout=60)
    if result.returncode != 17:
        raise RuntimeError('Dart owner-loss fixture did not reach its deliberate exit')
    event = json.loads(result.stdout)
    assert event['event'] == 'owner_ready' and isinstance(event['pid'], int) and event['pid'] > 0
    deadline = time.monotonic() + 20
    while True:
        script = f"if (Get-Process -Id {event['pid']} -ErrorAction SilentlyContinue) {{ 'alive' }} else {{ 'gone' }}"
        query = subprocess.run(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', script],
                               check=True, capture_output=True, text=True, timeout=10)
        state = query.stdout.strip()
        if state == 'gone':
            break
        if state != 'alive' or time.monotonic() >= deadline:
            raise RuntimeError('Owned TUN host survived the Dart parent exit')
        time.sleep(0.5)
    wait_tun_cleanup(name, baseline)


def run(binary, dart=None, stdio_host=False, tun=False):
    if tun and (os.name != 'nt' or os.environ.get('CI') != 'true' or not stdio_host or dart is None):
        raise RuntimeError('TUN probe requires the stdio host and disposable Windows CI')
    progress('Verify pinned binary version')
    version = subprocess.check_output([binary, 'version'], text=True, timeout=10)
    if version.splitlines()[0] != 'sing-box version 1.14.4':
        raise RuntimeError('The prototype requires sing-box 1.14.4')
    with tempfile.TemporaryDirectory(prefix='hotaru-sing-box-') as directory:
        certificate = pathlib.Path(directory) / 'certificate.pem'
        key = pathlib.Path(directory) / 'key.pem'
        openssl = shutil.which('openssl')
        if openssl is None:
            fallback = pathlib.Path('C:/Program Files/Git/usr/bin/openssl.exe')
            openssl = str(fallback) if fallback.exists() else None
        if openssl is None:
            raise RuntimeError('OpenSSL is required for the local HTTPS fixture')
        progress('Generate loopback HTTPS certificate')
        subprocess.run([
            openssl, 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
            '-keyout', str(key), '-out', str(certificate), '-days', '1',
            '-subj', '/CN=Hotaru P0 local fixture',
            '-addext', 'subjectAltName=IP:127.0.0.1,IP:198.18.7.2',
        ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=15)
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(certificate, key)
        with server(Origin, tls) as origin, server(Proxy) as first, server(Proxy) as second:
            first.origin_port = second.origin_port = origin.server_port
            api_port, mixed_port = port(), port()
            secret = uuid.uuid4().hex
            config = {
                'log': {'level': 'error'},
                'certificate': {'store': 'none', 'certificate_path': [str(certificate)]},
                'inbounds': [{'type': 'mixed', 'tag': 'mixed',
                              'listen': '127.0.0.1', 'listen_port': mixed_port}],
                'outbounds': [
                    {'type': 'http', 'tag': name, 'server': '127.0.0.1',
                     'server_port': instance.server_port}
                    for name, instance in [('node-a', first), ('node-b', second)]
                ] + [{'type': 'selector', 'tag': 'selected',
                      'outbounds': ['node-a', 'node-b']}],
                'route': {'final': 'selected', 'find_process': True},
                'experimental': {'clash_api': {
                    'external_controller': f'127.0.0.1:{api_port}',
                    'secret': secret}},
            }
            if dart is not None:
                progress('Compile profile fixture with Dart')
                profile_input = {
                    'nodes': [{'tag': 'node-a', 'port': first.server_port},
                              {'tag': 'node-b', 'port': second.server_port}],
                    'mixedPort': mixed_port, 'controllerPort': api_port, 'secret': secret,
                }
                compiled = subprocess.run([
                    dart, str(pathlib.Path(__file__).with_name('sing_box_adapter_smoke.dart')),
                    '--build-config',
                ], input=json.dumps(profile_input), text=True,
                    capture_output=True, check=True, timeout=20)
                config = json.loads(compiled.stdout)
                config['log'] = {'level': 'error'}
                config['certificate'] = {'store': 'none', 'certificate_path': [str(certificate)]}
                config['route']['find_process'] = True
            path = pathlib.Path(directory) / 'config.json'
            if dart is not None:
                progress('Compile protocol matrix with Dart')
                protocol_config = subprocess.run([
                    dart, str(pathlib.Path(__file__).with_name('sing_box_adapter_smoke.dart')),
                    '--build-protocol-config',
                ], text=True, capture_output=True, check=True, timeout=20)
                protocol_path = pathlib.Path(directory) / 'protocols.json'
                protocol_path.write_text(protocol_config.stdout, encoding='utf-8')
                subprocess.run([binary, 'check', '-c', str(protocol_path)], check=True, timeout=10)
            path.write_text(json.dumps(config), encoding='utf-8')
            progress('Validate compiled runtime configuration')
            subprocess.run([binary, 'check', '-c', str(path)], check=True, timeout=10)
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

            def api(endpoint, method='GET', payload=None):
                request = urllib.request.Request(
                    f'http://127.0.0.1:{api_port}{endpoint}', method=method,
                    data=json.dumps(payload).encode() if payload is not None else None,
                    headers={'Authorization': f'Bearer {secret}',
                             'Content-Type': 'application/json'})
                with opener.open(request, timeout=3) as response:
                    data = response.read()
                    return json.loads(data) if data else None

            with fixture_trust(certificate) as environment, \
                    (pathlib.Path(directory) / 'core.log').open('w+') as log:
                process = subprocess.Popen([binary, 'run', '-c', str(path)] +
                                           (['--stdio-control'] if stdio_host else []),
                                           stdout=log, stderr=log, cwd=directory,
                                           env=environment,
                                           stdin=subprocess.PIPE if stdio_host else None)
                try:
                    progress('Start isolated core and wait for controller')
                    deadline = time.monotonic() + 10
                    while True:
                        try:
                            core_version = api('/version')
                            break
                        except (OSError, urllib.error.URLError):
                            if process.poll() is not None or time.monotonic() >= deadline:
                                log.seek(0)
                                raise RuntimeError(log.read())
                            time.sleep(0.05)
                    proxies = api('/proxies')['proxies']
                    progress('Verify configuration reload capability rather than trusting HTTP status')
                    replacement = json.loads(json.dumps(config))
                    replacement['outbounds'][-1]['tag'] = 'replacement'
                    replacement['route']['final'] = 'replacement'
                    api('/configs', 'PUT', {'payload': json.dumps(replacement)})
                    unchanged = api('/proxies')['proxies']
                    assert 'selected' in unchanged and 'replacement' not in unchanged
                    target = f'https://127.0.0.1:{origin.server_port}/receipt'
                    client_tls = ssl.create_default_context(cafile=str(certificate))
                    for selected, instance, other in [
                            ('node-a', first, second), ('node-b', second, first)]:
                        progress(f'Verify controlled route {selected}')
                        api('/proxies/selected', 'PUT', {'name': selected})
                        assert api('/proxies/selected')['now'] == selected
                        before, other_before = len(instance.receipts), len(other.receipts)
                        connection = http.client.HTTPSConnection(
                            '127.0.0.1', mixed_port, timeout=3, context=client_tls)
                        connection.set_tunnel('127.0.0.1', origin.server_port)
                        try:
                            connection.request('GET', '/receipt')
                            response = connection.getresponse()
                            assert response.status == 200
                            assert response.read() == b'hotaru-sing-box-probe'
                        finally:
                            connection.close()
                        assert len(instance.receipts) == before + 1
                        assert len(other.receipts) == other_before
                    before = len(first.receipts)
                    progress('Verify node-specific HTTPS delay')
                    other_before = len(second.receipts)
                    delay = api('/proxies/node-a/delay?timeout=3000&url=' +
                                urllib.parse.quote(target, safe=''))
                    assert delay['delay'] > 0
                    assert len(first.receipts) == before + 1
                    assert len(second.receipts) == other_before
                    assert api('/proxies/selected')['now'] == 'node-b'
                    connection = http.client.HTTPSConnection(
                        '127.0.0.1', mixed_port, timeout=3, context=client_tls)
                    connection.set_tunnel('127.0.0.1', origin.server_port)
                    try:
                        connection.request('GET', '/hold')
                        response = connection.getresponse()
                        assert response.read(1) == b'h'
                        connections = api('/connections')
                        active = [entry for entry in connections['connections']
                                  if 'node-b' in entry['chains']]
                        assert len(active) == 1
                        entry = active[0]
                        expected_rule = 'final' if dart is None else 'clash_mode=rule => route(selected)'
                        assert entry['rule'] == expected_rule, entry['rule']
                        assert entry['metadata']['destinationPort'] == str(origin.server_port)
                        assert entry['upload'] > 0 and entry['download'] > 0
                        assert isinstance(entry['metadata']['processPath'], str)
                        if dart is not None:
                            progress('Verify live Dart adapter')
                            first_before, second_before = len(first.receipts), len(second.receipts)
                            dart_environment = dict(
                                os.environ,
                                HOTARU_PROBE_API=f'http://127.0.0.1:{api_port}',
                                HOTARU_PROBE_SECRET=secret,
                                HOTARU_PROBE_TARGET=target,
                                HOTARU_PROBE_PROFILE=json.dumps(profile_input),
                            )
                            subprocess.run([
                                dart, str(pathlib.Path(__file__).with_name(
                                    'sing_box_adapter_smoke.dart')),
                            ], check=True, timeout=20, env=dart_environment)
                            assert len(first.receipts) == first_before
                            assert len(second.receipts) == second_before + 1
                        origin.release.set()
                        if dart is None:
                            response.read()
                    finally:
                        origin.release.set()
                        connection.close()
                    report = {
                        'core': core_version,
                        'proxy_fields': sorted(proxies['selected']),
                        'connections_fields': sorted(connections),
                        'selection_receipts_verified': ['node-a', 'node-b'],
                        'node_specific_https_delay_verified': True,
                        'dart_adapter_verified': dart is not None,
                        'offline_final_route_preview_verified': dart is not None,
                        'dart_config_builder_verified': dart is not None,
                        'protocol_config_check_verified': dart is not None,
                        'clash_api_config_reload_supported': False,
                        'active_connection_fields': sorted(entry),
                        'metadata_fields': sorted(entry['metadata']),
                        'process_path_available': bool(entry['metadata']['processPath']),
                        'limits': ['Loopback HTTPS only; no remote protocol acceptance',
                                   'TUN and production UI remain unverified',
                                   'Only final-route chains verified; no multi-hop acceptance'],
                    }
                finally:
                    try:
                        if stdio_host:
                            process.communicate(b'stop\n', timeout=8)
                            if process.returncode != 0:
                                raise RuntimeError('Desktop host failed to close cleanly')
                        else:
                            process.terminate()
                            process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=5)
                        raise
                if dart is not None:
                    progress('Verify production desktop lifecycle with owned core processes')
                    before = len(second.receipts)
                    lifecycle_environment = dict(
                        environment,
                        HOTARU_PROBE_BINARY=binary,
                        HOTARU_PROBE_CONFIG=str(path),
                        HOTARU_PROBE_API=f'http://127.0.0.1:{api_port}',
                        HOTARU_PROBE_SECRET=secret,
                        HOTARU_PROBE_TARGET=target,
                        HOTARU_PROBE_STDIO='true' if stdio_host else 'false',
                    )
                    subprocess.run([
                        dart, str(pathlib.Path(__file__).with_name('sing_box_lifecycle_smoke.dart')),
                    ], check=True, timeout=90, env=lifecycle_environment)
                    assert len(second.receipts) == before + 1
                    report['desktop_lifecycle_verified'] = True
                    report['stdio_cleanup_acknowledgements_verified'] = stdio_host
                if tun:
                    progress('Verify real Windows TUN packets and cleanup')
                    name = 'HotaruP0-' + uuid.uuid4().hex[:8]
                    before = windows_snapshot(name)
                    if before['adapterCount'] or before['addressCount'] or before['routeCount']:
                        raise RuntimeError('Fixture interface or benchmark route is already in use')
                    compiled = subprocess.run([
                        dart, str(pathlib.Path(__file__).with_name('sing_box_adapter_smoke.dart')),
                        '--build-config',
                    ], input=json.dumps({
                        'nodes': [{'tag': 'node-a', 'port': first.server_port},
                                  {'tag': 'node-b', 'port': second.server_port}],
                        'mixedPort': mixed_port, 'controllerPort': api_port,
                        'secret': secret, 'tunName': name,
                    }), text=True, capture_output=True, check=True, timeout=20)
                    tun_config = json.loads(compiled.stdout)
                    tun_config['certificate'] = config['certificate']
                    tun_config['log'] = {'level': 'error'}
                    tun_config['route']['find_process'] = True
                    tun_path = pathlib.Path(directory) / 'tun.json'
                    tun_path.write_text(json.dumps(tun_config), encoding='utf-8')
                    subprocess.run([binary, 'check', '-c', str(tun_path)], check=True, timeout=10)
                    first.tun_target = second.tun_target = True
                    origin.release.clear()
                    first_before, second_before = len(first.receipts), len(second.receipts)
                    tun_environment = dict(lifecycle_environment,
                        HOTARU_PROBE_CONFIG=str(tun_path), HOTARU_PROBE_CA=str(certificate),
                        HOTARU_PROBE_TUN_TARGET=f'https://198.18.7.2:{origin.server_port}')
                    subprocess.run([
                        dart, str(pathlib.Path(__file__).with_name('sing_box_tun_smoke.dart')),
                    ], check=True, timeout=90, env=tun_environment)
                    expected = f'198.18.7.2:{origin.server_port}'
                    assert first.receipts[first_before:] == [expected]
                    assert second.receipts[second_before:] == [expected]
                    wait_tun_cleanup(name, before)
                    progress('Verify TUN cleanup when the parent control pipe closes')
                    host_eof_probe(binary, tun_path, environment, name, before,
                                   pathlib.Path(directory) / 'host-eof.log')
                    progress('Verify TUN cleanup after the actual Dart owner exits abruptly')
                    owner_loss_probe(dart, tun_environment, name, before)
                    report['windows_tun_verified'] = True
                    report['tun_cleanup_verified'] = True
                    report['parent_eof_cleanup_verified'] = True
                    report['dart_owner_loss_cleanup_verified'] = True
                    report['limits'] = ['Controlled HTTPS only; no remote protocol acceptance',
                                        'Production UI and privileged helper integration remain unverified',
                                        'Only final-route chains verified; no multi-hop acceptance']
                return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True)
    parser.add_argument('--dart')
    parser.add_argument('--stdio-host', action='store_true')
    parser.add_argument('--tun', action='store_true')
    args = parser.parse_args()
    print(json.dumps(run(str(pathlib.Path(args.binary).resolve()), args.dart, args.stdio_host, args.tun), indent=2))
