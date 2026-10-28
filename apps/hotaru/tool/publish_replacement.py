import hashlib
import json
import os
import re
import subprocess
from pathlib import Path

from verify_release_assets import verify


def gh(*args):
    return subprocess.check_output(['gh', *args], text=True)


def main():
    version = re.search(r'^version: ([0-9.]+)', Path('pubspec.yaml').read_text(), re.M)[1]
    code = int(re.search(r'^hotaruVersionCode=(\d+)', Path('android/gradle.properties').read_text(), re.M)[1])
    root = Path('verified')
    checksums = verify(root, version)
    for name, digest in checksums.items():
        with (Path('built') / name).open('rb') as stream:
            if hashlib.file_digest(stream, 'sha256').hexdigest() != digest:
                raise ValueError(f'Draft differs from this run: {name}')
    repo = os.environ['GITHUB_REPOSITORY']
    source = os.environ['GITHUB_SHA']
    releases = json.loads(gh('api', f'repos/{repo}/releases?per_page=100'))
    matches = [release for release in releases if release['tag_name'] == f'v{version}']
    if len(matches) != 1:
        raise ValueError('Expected one versioned release')
    release = matches[0]
    if not release['draft']:
        raise ValueError('Candidate must remain a draft until verification finishes')
    body = re.sub(rf'(releases/download/v{re.escape(version)}/[^"\s<>]+\.(?:apk|exe|zip))', rf'\1?build={code}', release['body'])
    patch = {
        'draft': False, 'prerelease': True, 'make_latest': 'false',
        'target_commitish': source, 'name': f'Hotaru v{version} · 仪表盘改版测试版',
        'body': body,
    }
    patch_path = Path(os.environ['RUNNER_TEMP']) / 'hotaru-publish.json'
    patch_path.write_text(json.dumps(patch))
    result = json.loads(gh('api', '--method', 'PATCH', f"repos/{repo}/releases/{release['id']}", '--input', str(patch_path)))
    if result['draft'] or result['tag_name'] != f'v{version}':
        raise ValueError('Release was not published')
    try:
        tags = subprocess.check_output(['git', 'ls-remote', 'origin', f'refs/tags/v{version}', f'refs/tags/v{version}^{{}}'], text=True)
        refs = {line.split()[1]: line.split()[0] for line in tags.splitlines()}
        target = refs.get(f'refs/tags/v{version}^{{}}', refs.get(f'refs/tags/v{version}'))
        if target != source:
            raise ValueError('Published tag does not match the built source')
        checksums['SHA256SUMS'] = hashlib.sha256((root / 'SHA256SUMS').read_bytes()).hexdigest()
        for name, digest in checksums.items():
            dest = Path(os.environ['RUNNER_TEMP']) / name
            subprocess.run(['curl', '-fLsS', '--retry', '3', f'https://github.com/{repo}/releases/download/v{version}/{name}?build={code}', '-o', str(dest)], check=True)
            with dest.open('rb') as stream:
                if hashlib.file_digest(stream, 'sha256').hexdigest() != digest:
                    raise ValueError(f'Public download mismatch: {name}')
    except Exception:
        patch_path.write_text(json.dumps({'draft': True, 'prerelease': True}))
        gh('api', '--method', 'PATCH', f"repos/{repo}/releases/{release['id']}", '--input', str(patch_path))
        raise
    receipt = {'url': result['html_url'], 'release_id': result['id'], 'source': source, 'base_version_code': code, 'sha256': checksums}
    Path('release-verification.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt, indent=2))


if __name__ == '__main__':
    main()
