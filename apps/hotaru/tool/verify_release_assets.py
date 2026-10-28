import hashlib
import json
import re
import sys
from pathlib import Path


def verify(folder, version):
    expected = {
        f'Hotaru-{version}-windows-amd64-setup.exe',
        f'Hotaru-{version}-windows-amd64.zip',
        *(f'Hotaru-{version}-android-{abi}.apk' for abi in ['arm64-v8a', 'armeabi-v7a', 'x86_64']),
        'ANDROID-VERIFICATION.json',
    }
    if {p.name for p in folder.iterdir()} != expected | {'SHA256SUMS'}:
        raise ValueError('Unexpected or missing release files')
    checksums = {}
    for line in (folder / 'SHA256SUMS').read_text().splitlines():
        match = re.fullmatch(r'([0-9a-f]{64})  (?:\./)?([^/]+)', line)
        if not match or match[2] in checksums:
            raise ValueError('Invalid checksum manifest')
        checksums[match[2]] = match[1]
    if set(checksums) != expected:
        raise ValueError('Checksum manifest does not match the release')
    for name, digest in checksums.items():
        with (folder / name).open('rb') as stream:
            actual = hashlib.file_digest(stream, 'sha256').hexdigest()
        if digest != actual:
            raise ValueError(f'Checksum mismatch: {name}')
    return checksums


if __name__ == '__main__':
    print(json.dumps(verify(Path(sys.argv[1]), sys.argv[2]), indent=2))
