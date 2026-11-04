"""Exercise the pinned sing-box clash_api against controlled loopback traffic."""

import argparse
import contextlib
import http.client
import http.server
import json
import pathlib
import select
import socket
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
        self.send_response(200)
        self.send_header('Content-Length', '0')
        self.end_headers()

    def do_GET(self):
        body = b'hotaru-sing-box-probe'
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

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
                readable, _, _ = select.select(sockets, [], [], 3)
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
def server(handler):
    instance = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler)
    instance.receipts = []
    thread = threading.Thread(target=instance.serve_forever, daemon=True)
    thread.start()
    try:
        yield instance
    finally:
        instance.shutdown()
        instance.server_close()
        thread.join()


def port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def run(binary):
    version = subprocess.check_output([binary, 'version'], text=True)
    if version.splitlines()[0] != 'sing-box version 1.14.4':
        raise RuntimeError('The prototype requires sing-box 1.14.4')
    with tempfile.TemporaryDirectory(prefix='hotaru-sing-box-') as directory:
        with server(Origin) as origin, server(Proxy) as first, server(Proxy) as second:
            first.origin_port = second.origin_port = origin.server_port
            api_port, mixed_port = port(), port()
            secret = uuid.uuid4().hex
            config = {
                'log': {'level': 'error'},
                'inbounds': [{'type': 'mixed', 'tag': 'mixed',
                              'listen': '127.0.0.1', 'listen_port': mixed_port}],
                'outbounds': [
                    {'type': 'http', 'tag': name, 'server': '127.0.0.1',
                     'server_port': instance.server_port}
                    for name, instance in [('node-a', first), ('node-b', second)]
                ] + [{'type': 'selector', 'tag': 'selected',
                      'outbounds': ['node-a', 'node-b']}],
                'route': {'final': 'selected'},
                'experimental': {'clash_api': {
                    'external_controller': f'127.0.0.1:{api_port}',
                    'secret': secret}},
            }
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

            with (pathlib.Path(directory) / 'core.log').open('w+') as log:
                process = subprocess.Popen([binary, 'run', '-c', str(path)],
                                           stdout=log, stderr=log, cwd=directory)
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
                    target = f'http://127.0.0.1:{origin.server_port}/receipt'
                    for selected, instance, other in [
                            ('node-a', first, second), ('node-b', second, first)]:
                        api('/proxies/selected', 'PUT', {'name': selected})
                        assert api('/proxies/selected')['now'] == selected
                        before, other_before = len(instance.receipts), len(other.receipts)
                        connection = http.client.HTTPConnection('127.0.0.1', mixed_port,
                                                                timeout=3)
                        try:
                            connection.request('GET', target)
                            response = connection.getresponse()
                            assert response.status == 200
                            assert response.read() == b'hotaru-sing-box-probe'
                        finally:
                            connection.close()
                        assert len(instance.receipts) == before + 1
                        assert len(other.receipts) == other_before
                    before = len(first.receipts)
                    try:
                        api('/proxies/node-a/delay?timeout=3000&url=' +
                            urllib.parse.quote(target, safe=''))
                        raise RuntimeError('Expected rejection of the HTTP delay target')
                    except urllib.error.HTTPError as error:
                        assert error.code == 503
                        error.read()
                    assert len(first.receipts) == before
                    connections = api('/connections')
                    return {
                        'core': core_version,
                        'proxy_fields': sorted(proxies['selected']),
                        'connections_fields': sorted(connections),
                        'selection_receipts_verified': ['node-a', 'node-b'],
                        'http_delay_target_rejected': True,
                        'limits': ['Loopback HTTP only; no remote protocol acceptance',
                                   'Windows and TUN remain unverified',
                                   'Delay requires an HTTPS fixture; HTTP URL is discarded',
                                   'No live connection field coverage yet'],
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
    args = parser.parse_args()
    print(json.dumps(run(str(pathlib.Path(args.binary).resolve())), indent=2))
