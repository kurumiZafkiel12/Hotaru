import argparse
import hashlib
import json
import os
import re
import subprocess
import zipfile
from pathlib import Path

CERTIFICATE = '7963ba5a3728d320e82cdfb43d58f7d32bdffd419113e2850de7ea2f2b987faa'
ABI_CODES = {'armeabi-v7a': 1000, 'arm64-v8a': 2000, 'x86_64': 4000}


def command(*arguments):
    return subprocess.check_output(arguments, text=True)


def verify(dist, android_home):
    version = re.search(r'^version: ([0-9.]+)', Path('pubspec.yaml').read_text(), re.M)[1]
    code = int(re.search(r'^hotaruVersionCode=(\d+)', Path('android/gradle.properties').read_text(), re.M)[1])
    build_number = re.search(r'^version: [0-9.]+\+(\d+)\s*$', Path('pubspec.yaml').read_text(), re.M)
    if not build_number or int(build_number[1]) != code:
        raise RuntimeError('Flutter build number and Android base versionCode must agree')
    build_tools = next(
        path for path in sorted((android_home / 'build-tools').iterdir(), reverse=True)
        if (path / 'aapt').is_file() and (path / 'apksigner').is_file()
    )
    apks = list(dist.glob('*.apk'))
    if len(apks) != len(ABI_CODES):
        raise RuntimeError(f'Expected three split APKs, got {len(apks)}')
    reports = []
    for abi, offset in ABI_CODES.items():
        files = [path for path in apks if path.name.endswith(f'-android-{abi}.apk')]
        if len(files) != 1:
            raise RuntimeError(f'Missing or duplicate APK for {abi}')
        apk = files[0]
        badging = command(str(build_tools / 'aapt'), 'dump', 'badging', str(apk))
        package = re.search(r"package: name='([^']+)' versionCode='(\d+)' versionName='([^']+)'", badging)
        native = re.search(r'^native-code: (.+)$', badging, re.M)
        if not package or package[1] != 'dev.hotaru.hotaru' or package[3] != version or int(package[2]) != code + offset:
            raise RuntimeError(f'Unexpected package/version for {apk.name}')
        if not native or re.findall(r"'([^']+)'", native[1]) != [abi]:
            raise RuntimeError(f'Unexpected ABI for {apk.name}')
        signing = command(str(build_tools / 'apksigner'), 'verify', '--verbose', '--print-certs', str(apk))
        certificates = re.findall(r'certificate SHA-256 digest:\s*([0-9a-fA-F]+)', signing)
        if not certificates or {value.lower() for value in certificates} != {CERTIFICATE}:
            raise RuntimeError(f'Persistent signing certificate mismatch: {apk.name}')
        with zipfile.ZipFile(apk) as archive:
            if archive.testzip() is not None:
                raise RuntimeError(f'Corrupt APK: {apk.name}')
            names = set(archive.namelist())
            required = {
                'AndroidManifest.xml', 'classes.dex',
                'assets/flutter_assets/assets/fonts/JetBrainsMono-OFL.txt',
                'assets/flutter_assets/assets/images/services/LICENSE.md',
            } | {
                f'lib/{abi}/{library}' for library in ['libclash.so', 'librust_api.so', 'libflutter.so', 'libapp.so']
            }
            if not required.issubset(names):
                raise RuntimeError(f'Incomplete APK: {apk.name}')
            font_license = archive.read('assets/flutter_assets/assets/fonts/JetBrainsMono-OFL.txt').decode()
            if 'JetBrains Mono Project Authors' not in font_license or 'SIL OPEN FONT LICENSE' not in font_license:
                raise RuntimeError(f'Missing bundled font license: {apk.name}')
        with apk.open('rb') as stream:
            digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        reports.append({
            'file': apk.name, 'bytes': apk.stat().st_size, 'sha256': digest,
            'package': package[1], 'version': version, 'version_code': int(package[2]),
            'abi': abi, 'certificate_sha256': CERTIFICATE,
        })
    return reports


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--dist', type=Path, default=Path('dist'))
    parser.add_argument('--android-home', type=Path, default=Path(os.environ.get('ANDROID_HOME', '')))
    parser.add_argument('--output', type=Path, default=Path('dist/ANDROID-VERIFICATION.json'))
    args = parser.parse_args()
    result = verify(args.dist, args.android_home)
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
