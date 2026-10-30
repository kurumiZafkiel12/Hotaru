import json
import os
import pathlib
import re
import subprocess
import time


def adb(*arguments):
    return subprocess.run(['adb', *arguments], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=120).stdout


def main():
    serial = adb('get-serialno').strip()
    if not serial.startswith('emulator-'):
        raise RuntimeError('Native ICE validation requires its disposable emulator')
    apk = pathlib.Path('ice-probe/hotaru-native-ice.apk')
    if not apk.is_file():
        raise FileNotFoundError('Native ICE harness APK absent')
    adb('logcat', '-c')
    adb('install', '-r', str(apk))
    adb('shell', 'am', 'start', '-W', '-n', 'dev.hotaru.hotaru/.MainActivity')
    result = None
    for _ in range(45):
        text = adb('logcat', '-d', '-s', 'flutter')
        matches = re.findall(r'HOTARU_NATIVE_ICE (\{[^\r\n]+\})', text)
        if matches:
            result = json.loads(matches[-1])
            break
        time.sleep(1)
    if result is None:
        raise AssertionError('Native ICE harness produced no result')
    output = pathlib.Path('archive-probe/native-ice')
    output.mkdir(parents=True, exist_ok=True)
    result['android_api'] = int(adb('shell', 'getprop', 'ro.build.version.sdk').strip())
    (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    if result.get('source_sha') != os.environ['GITHUB_SHA']:
        raise AssertionError('Native ICE result does not match current source')
    if result.get('safe_mode') is not True or result.get('plugin_started') is not True:
        raise AssertionError('Native ICE plugin failed to gather actual candidates')
    if result.get('verdict_without_expected_exit') != 'inconclusive':
        raise AssertionError('Missing expected exit was incorrectly treated as safe')
    print('::notice title=Native Android ICE::' + json.dumps(result))


if __name__ == '__main__':
    main()
