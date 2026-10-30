import ipaddress
import json
import pathlib
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET


OUTPUT = pathlib.Path('archive-probe/network-ui')
OUTPUT.mkdir(parents=True, exist_ok=True)
PACKAGE = 'dev.hotaru.hotaru'


def adb(*arguments, binary=False):
    result = subprocess.run(['adb', *arguments], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)
    return result.stdout if binary else result.stdout.decode('utf-8', errors='replace')


def hierarchy(name='current'):
    adb('shell', 'uiautomator', 'dump', '--compressed', '/sdcard/hotaru-network-ui.xml')
    text = adb('shell', 'cat', '/sdcard/hotaru-network-ui.xml')
    (OUTPUT / f'{name}.xml').write_text(text)
    return ET.fromstring(text)


def label(node):
    return (node.get('text', '') or node.get('content-desc', '')).strip()


def matching(root, names):
    nodes = []
    for node in root.iter('node'):
        text = label(node)
        if any(text == name or text.startswith(name + '\n') for name in names):
            bounds = [int(value) for value in re.findall(r'\d+', node.get('bounds', ''))]
            if len(bounds) == 4 and bounds[2] > bounds[0] and bounds[3] > bounds[1]:
                nodes.append((node.get('clickable') != 'true', (bounds[2] - bounds[0]) * (bounds[3] - bounds[1]), node, bounds))
    return sorted(nodes, key=lambda value: value[:2])


def find(names, scrolls=0):
    for index in range(scrolls + 1):
        root = hierarchy()
        nodes = matching(root, names)
        if nodes:
            return nodes[0][2:]
        if index < scrolls:
            size = re.findall(r'(\d+)x(\d+)', adb('shell', 'wm', 'size'))[-1]
            width, height = map(int, size)
            adb('shell', 'input', 'swipe', str(width // 2), str(height * 3 // 4), str(width // 2), str(height // 3), '350')
            time.sleep(0.4)
    raise AssertionError('UI label unavailable: ' + '/'.join(names))


def tap(names, scrolls=0):
    _, (left, top, right, bottom) = find(names, scrolls)
    adb('shell', 'input', 'tap', str((left + right) // 2), str((top + bottom) // 2))
    time.sleep(0.8)


def screenshot(name):
    (OUTPUT / f'{name}.png').write_bytes(adb('exec-out', 'screencap', '-p', binary=True))


def open_system_settings(names):
    tap(names, scrolls=6)
    for _ in range(8):
        activity = adb('shell', 'dumpsys', 'activity', 'activities')
        if re.search(r'(?:mResumedActivity|topResumedActivity)[^\n]*com\.android\.settings', activity):
            screenshot('settings-' + names[0].replace(' ', '-'))
            adb('shell', 'input', 'keyevent', 'KEYCODE_BACK')
            time.sleep(1)
            return
        time.sleep(0.4)
    raise AssertionError('System settings did not become foreground')


def main():
    api = int(adb('shell', 'getprop', 'ro.build.version.sdk').strip())
    time.sleep(2)
    tap(['Tools', '工具'])
    tap(['Android network tools', 'Android 网络维护'], scrolls=12)
    find(['System DNS servers', '系统 DNS 服务器'], scrolls=8)
    time.sleep(1)
    root = hierarchy('observed')
    text = '\n'.join(label(node) for node in root.iter('node'))
    if 'Network status could not be read' in text or '无法读取网络状态' in text:
        raise AssertionError('Native system network snapshot unavailable')
    addresses = set()
    for token in re.findall(r'[0-9a-fA-F:.]+(?:%[A-Za-z0-9_.-]+)?', text):
        try:
            address = ipaddress.ip_address(token.split('%')[0])
            addresses.add(str(address))
        except ValueError:
            pass
    if not addresses:
        raise AssertionError('No native DNS server address rendered')
    screenshot('network-snapshot')
    open_system_settings(['VPN'])
    if api >= 28:
        open_system_settings(['System Private DNS', '系统私人 DNS'])
    result = {'api': api, 'native_snapshot_rendered': True, 'dns_server_count': len(addresses), 'vpn_settings_opened': True, 'private_dns_settings_opened': api >= 28, 'scope': 'Disposable Android emulator; read-only system observations and opening settings only; no VPN toggles or leakage verdict'}
    (OUTPUT / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print('::notice title=Native Android network tools::' + json.dumps(result))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        try:
            hierarchy('failure')
            screenshot('failure')
        except Exception:
            pass
        print('Native Android network UI check failed:', type(error).__name__, str(error), file=sys.stderr)
        raise
