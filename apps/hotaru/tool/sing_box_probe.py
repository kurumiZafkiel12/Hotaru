"""Exercise the pinned sing-box clash_api against controlled loopback traffic."""

import argparse
import contextlib
import http.client
import http.server
import json
import os
import pathlib
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


class Origin(http.server.BaseHTTPRequestHandler):
    def do_HEAD(self):
        time.sleep(0.025)
        self.send_response(200)
        self.send_header('Content-Length', '0')
        self.end_headers()

    def do_GET(self):
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
        if host != '127.0.0.1' or int(destination_port) != self.server.origin_port:
            self.send_error(403)
            return
        with socket.create_connection((host, int(destination_port)), timeout=3) as upstream:
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


@contextlib.contextmanager
def server(handler, tls=None):
    instance = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler)
    instance.receipts = []
    instance.release = threading.Event()
    if tls is not None:
        instance.socket = tls.wrap_socket(instance.socket, server_side=True)
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
    subprocess.run(['certutil', '-user', '-addstore', 'Root', str(certificate)],
                   check=True, stdout=subprocess.DEVNULL)
    try:
        yield environment
    finally:
        subprocess.run(['certutil', '-user', '-delstore', 'Root', thumbprint],
                       check=True, stdout=subprocess.DEVNULL)


def run(binary, dart=None):
    version = subprocess.check_output([binary, 'version'], text=True)
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
        subprocess.run([
            openssl, 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
            '-keyout', str(key), '-out', str(certificate), '-days', '1',
            '-subj', '/CN=Hotaru P0 local fixture',
            '-addext', 'subjectAltName=IP:127.0.0.1',
        ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
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
                compiled = subprocess.run([
                    dart, str(pathlib.Path(__file__).with_name('sing_box_adapter_smoke.dart')),
                    '--build-config',
                ], input=json.dumps({
                    'nodes': [{'tag': 'node-a', 'port': first.server_port},
                              {'tag': 'node-b', 'port': second.server_port}],
                    'mixedPort': mixed_port, 'controllerPort': api_port, 'secret': secret,
                }), text=True, capture_output=True, check=True, timeout=20)
                config = json.loads(compiled.stdout)
                config['log'] = {'level': 'error'}
                config['certificate'] = {'store': 'none', 'certificate_path': [str(certificate)]}
                config['route']['find_process'] = True
            path = pathlib.Path(directory) / 'config.json'
            path.write_text(json.dumps(config), encoding='utf-8')
            subprocess.run([binary, 'check', '-c', str(path)], check=True)
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
                process = subprocess.Popen([binary, 'run', '-c', str(path)],
                                           stdout=log, stderr=log, cwd=directory,
                                           env=environment)
                try:
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
                    target = f'https://127.0.0.1:{origin.server_port}/receipt'
                    client_tls = ssl.create_default_context(cafile=str(certificate))
                    for selected, instance, other in [
                            ('node-a', first, second), ('node-b', second, first)]:
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
                        assert entry['rule'] == 'final'
                        assert entry['metadata']['destinationPort'] == str(origin.server_port)
                        assert entry['upload'] > 0 and entry['download'] > 0
                        assert isinstance(entry['metadata']['processPath'], str)
                        if dart is not None:
                            first_before, second_before = len(first.receipts), len(second.receipts)
                            dart_environment = dict(
                                os.environ,
                                HOTARU_PROBE_API=f'http://127.0.0.1:{api_port}',
                                HOTARU_PROBE_SECRET=secret,
                                HOTARU_PROBE_TARGET=target,
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
                    return {
                        'core': core_version,
                        'proxy_fields': sorted(proxies['selected']),
                        'connections_fields': sorted(connections),
                        'selection_receipts_verified': ['node-a', 'node-b'],
                        'node_specific_https_delay_verified': True,
                        'dart_adapter_verified': dart is not None,
                        'dart_config_builder_verified': dart is not None,
                        'active_connection_fields': sorted(entry),
                        'metadata_fields': sorted(entry['metadata']),
                        'process_path_available': bool(entry['metadata']['processPath']),
                        'limits': ['Loopback HTTPS only; no remote protocol acceptance',
                                   'Windows and TUN remain unverified',
                                   'Only final-route chains verified; no multi-hop acceptance'],
                    }
                finally:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=5)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True)
    parser.add_argument('--dart')
    args = parser.parse_args()
    print(json.dumps(run(str(pathlib.Path(args.binary).resolve()), args.dart), indent=2))
