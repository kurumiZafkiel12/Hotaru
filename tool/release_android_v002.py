import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile


REPO = 'kurumiZafkiel12/Hotaru'
TAG = 'v0.0.2'
ABIS = ('arm64-v8a', 'armeabi-v7a', 'x86_64')
OUTPUT = Path('android-release')


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def inspect():
    sdk = Path(os.environ['ANDROID_HOME'])
    tools = sorted((sdk / 'build-tools').iterdir(), key=lambda p: tuple(int(x) for x in re.findall(r'\d+', p.name)))
    tools = next(p for p in reversed(tools) if (p / 'apksigner').exists() and (p / 'aapt').exists())
    report = []
    for abi in ABIS:
        with tempfile.TemporaryDirectory() as previous:
            previous_name = f'Hotaru-0.0.1-android-{abi}.apk'
            subprocess.run(['gh', 'release', 'download', 'v0.0.1', '--repo', REPO, '--pattern', previous_name, '--dir', previous], check=True)
            old_apk = Path(previous) / previous_name
            old_metadata = command(str(tools / 'aapt'), 'dump', 'badging', str(old_apk))
            old_package = re.search(r"package: name='([^']+)' versionCode='([^']+)' versionName='([^']+)'", old_metadata)
            if not old_package or old_package.group(1) != 'dev.hotaru.hotaru.dev' or old_package.group(3) != '0.0.1':
                raise RuntimeError('Unexpected v0.0.1 baseline APK metadata')
            previous_code = int(old_package.group(2))
            old_signing = command(str(tools / 'apksigner'), 'verify', '--print-certs', str(old_apk))
            previous_certificate = re.search(r'certificate SHA-256 digest:\s*(\w+)', old_signing).group(1)
        matches = list(Path('dist').rglob(f'*-android-{abi}.apk'))
        if len(matches) != 1:
            raise RuntimeError(f'Expected one packaged {abi} APK, found {matches}')
        source = matches[0]
        metadata = command(str(tools / 'aapt'), 'dump', 'badging', str(source))
        package = re.search(r"package: name='([^']+)' versionCode='([^']+)' versionName='([^']+)'", metadata)
        if not package or package.group(1) not in ('dev.hotaru.hotaru', 'dev.hotaru.hotaru.dev') or (int(package.group(2)) != previous_code + 1 or package.group(3) != '0.0.2'):
            raise RuntimeError(f'Unexpected package metadata: {package.group(0) if package else "missing"}')
        signing = command(str(tools / 'apksigner'), 'verify', '--verbose', '--print-certs', str(source))
        certificate = re.search(r'certificate SHA-256 digest:\s*(\w+)', signing)
        if not certificate:
            raise RuntimeError('Verified signing certificate missing')
        with zipfile.ZipFile(source) as archive:
            if archive.testzip() is not None:
                raise RuntimeError(f'Corrupt APK: {source.name}')
            for library in ('libclash.so', 'libflutter.so', 'libapp.so', 'librust_api.so'):
                if f'lib/{abi}/{library}' not in archive.namelist():
                    raise RuntimeError(f'{abi}: missing {library}')
        target = OUTPUT / f'Hotaru-0.0.2-android-{abi}.apk'
        shutil.copy2(source, target)
        report.append({'name': target.name, 'package': package.group(1), 'version_code': int(package.group(2)), 'previous_version_code': previous_code, 'version_name': '0.0.2', 'certificate_sha256': certificate.group(1), 'previous_certificate_sha256': previous_certificate, 'upgrade_signature_match': certificate.group(1) == previous_certificate, 'sha256': digest(target)})
    if len({item['certificate_sha256'] for item in report}) != 1:
        raise RuntimeError('APK architectures have different signing certificates')
    (OUTPUT / 'verification.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


def release_body(body, package, upgrade_signature_match=False, version_codes="见 APK 元数据"):
    if '<!-- android-v002-supplement -->' in body:
        raise RuntimeError('Android supplement already exists; inspect before replacing it')
    if 'Hotaru-0.0.2-android-' in body:
        raise RuntimeError('Existing Android links need manual reconciliation')
    links = '\n'.join(
        f'<a href="https://github.com/{REPO}/releases/download/{TAG}/Hotaru-0.0.2-android-{abi}.apk"><img src="https://img.shields.io/badge/APK-{abi.replace("-", "--")}-3ddc84.svg?logo=android"></a><br>'
        for abi in ABIS
    )
    row = f'<tr><td>Android</td><td>\n{links}\n</td></tr>\n'
    if body.count('</tbody>') != 1:
        raise RuntimeError('Expected the existing single download table')
    body = body.replace('</tbody>', row + '</tbody>')
    body = body.replace('Windows x64 release. Android, macOS and Linux packages are not included in this release.', 'Windows x64 and Android APKs are available. macOS and Linux packages are not included.')
    if package.endswith('.dev'):
        if upgrade_signature_match:
            signing = '安卓为调试签名预览包（dev.hotaru.hotaru.dev）；已核对与 v0.0.1 APK 签名证书一致、对应架构 versionCode 递增，具备覆盖安装的包元数据条件。实际升级和数据保留仍待实机验证。不要把本包当作正式签名版。'
        else:
            signing = '安卓为调试签名预览包（dev.hotaru.hotaru.dev），已核对其签名证书与 v0.0.1 不同，不能直接覆盖旧包。请先在旧版备份，再卸载旧版并安装此包；卸载会删除应用数据。不要把本包当作正式签名版。'
    else:
        signing = '安卓包名为 dev.hotaru.hotaru，使用仓库已有发布签名；与旧调试包 .dev 不是同一个应用，不会自动迁移其数据。'
    return body + f'\n\n<!-- android-v002-supplement -->\n### Android v0.0.2 补充\n\n按设备架构选择上表 APK，普通近年手机优先 arm64-v8a。版本 0.0.2，内部构建号 11；各 APK versionCode：{version_codes}。基于 v0.0.2 main 及已合入的安卓签名回退修正；不包含 v0.0.3 修改。\n\n{signing}\n\n已检查 APK 版本、签名、各架构原生库和 SHA256；构建及自动化检查不能替代安卓实机的 VPN 授权、代理链路、后台运行与升级验收。请核对同页 SHA256SUMS。原 Windows 资产保持不变。\n'


def publish():
    release = json.loads(command('gh', 'api', f'repos/{REPO}/releases/tags/{TAG}'))
    if release['draft'] or release['prerelease'] or release['tag_name'] != TAG:
        raise RuntimeError('Expected existing stable v0.0.2 release')
    report = json.loads((OUTPUT / 'verification.json').read_text())
    expected = {f'Hotaru-0.0.2-android-{abi}.apk' for abi in ABIS}
    if {item['name'] for item in report} != expected:
        raise RuntimeError('Unexpected APK set')
    existing = {item['name'] for item in release['assets']}
    if existing & expected:
        raise RuntimeError('Android assets already exist; do not overwrite a concurrent release')
    windows = {name for name in existing if name.endswith(('.exe', '.zip'))}
    if not windows or 'SHA256SUMS' not in existing:
        raise RuntimeError('Existing Windows assets or checksum manifest missing')
    codes = '、'.join(f'{abi}={next(item["version_code"] for item in report if abi in item["name"])}' for abi in ABIS)
    body = release_body(release['body'], report[0]['package'], all(item['upgrade_signature_match'] for item in report), codes)
    with tempfile.TemporaryDirectory() as temporary:
        temp = Path(temporary)
        subprocess.run(['gh', 'release', 'download', TAG, '--repo', REPO, '--pattern', 'SHA256SUMS', '--dir', temporary], check=True)
        checksum_path = temp / 'SHA256SUMS'
        old = checksum_path.read_text()
        rows = {line[66:].removeprefix('./'): line[:64] for line in old.splitlines() if re.fullmatch(r'[a-fA-F0-9]{64}  .+', line)}
        if not windows <= rows.keys():
            raise RuntimeError('Windows manifest entries missing')
        additions = []
        for item in report:
            path = OUTPUT / item['name']
            if digest(path) != item['sha256']:
                raise RuntimeError('APK changed since inspection')
            additions.append(f'{item["sha256"]}  {item["name"]}')
        checksum_path.write_text(old.rstrip() + '\n' + '\n'.join(additions) + '\n')
        for item in report:
            subprocess.run(['gh', 'release', 'upload', TAG, '--repo', REPO, str(OUTPUT / item['name'])], check=True)
        downloaded = temp / 'downloaded'
        downloaded.mkdir()
        for item in report:
            subprocess.run(['gh', 'release', 'download', TAG, '--repo', REPO, '--pattern', item['name'], '--dir', str(downloaded)], check=True)
            if digest(downloaded / item['name']) != item['sha256']:
                raise RuntimeError('Uploaded APK download hash mismatch')
        current = json.loads(command('gh', 'api', f'repos/{REPO}/releases/{release["id"]}'))
        if current['body'] != release['body']:
            raise RuntimeError('Release body changed concurrently; preserve it')
        subprocess.run(['gh', 'release', 'upload', TAG, '--repo', REPO, str(checksum_path), '--clobber'], check=True)
        body_path = temp / 'release.md'
        body_path.write_text(body)
        subprocess.run(['gh', 'release', 'edit', TAG, '--repo', REPO, '--notes-file', str(body_path)], check=True)
        print(f'Updated https://github.com/{REPO}/releases/tag/{TAG}')


if __name__ == '__main__':
    try:
        {'inspect': inspect, 'publish': publish}[sys.argv[1]]()
    except Exception as error:
        print('::error::' + str(error).replace('\n', ' '), flush=True)
        raise
