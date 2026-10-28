import json
import os
import re
import subprocess
import sys
from pathlib import Path


def git(*args, **kwargs):
    return subprocess.check_output(['git', *args], **kwargs).decode().strip()


def main():
    phase = sys.argv[1]
    version = re.search(r'^version: ([0-9.]+)', Path('pubspec.yaml').read_text(), re.M)[1]
    ref = f'refs/heads/ci/release-status/v{version}'
    receipt = {
        'phase': phase,
        'source': os.environ.get('HOTARU_RELEASE_SOURCE', os.environ['GITHUB_SHA']),
        'workflow_source': os.environ['GITHUB_SHA'],
        'run': os.environ['GITHUB_RUN_ID'],
        'url': f"https://github.com/{os.environ['GITHUB_REPOSITORY']}/actions/runs/{os.environ['GITHUB_RUN_ID']}",
        'results': json.loads(os.environ.get('JOB_RESULTS', '{}')),
    }
    try:
        jobs = json.loads(subprocess.check_output(['gh', 'api',
            f"repos/{os.environ['GITHUB_REPOSITORY']}/actions/runs/{os.environ['GITHUB_RUN_ID']}/jobs?per_page=100"], text=True))
        receipt['jobs'] = [{key: job.get(key) for key in ['id', 'name', 'conclusion', 'status']} for job in jobs['jobs']]
    except subprocess.CalledProcessError:
        receipt['jobs'] = []
    if Path('release-verification.json').is_file():
        receipt['verification'] = json.loads(Path('release-verification.json').read_text())
    remote = git('ls-remote', 'origin', ref)
    parents = []
    if remote:
        parent = remote.split()[0]
        git('fetch', 'origin', ref)
        parents = ['-p', parent]
    if remote and 'verification' not in receipt:
        previous = json.loads(git('show', f'{parent}:receipt.json'))
        if previous.get('source') == receipt['source'] and 'verification' in previous:
            receipt['verification'] = previous['verification']
    blob = git('hash-object', '-w', '--stdin', input=(json.dumps(receipt, indent=2) + '\n').encode())
    tree = git('mktree', input=f'100644 blob {blob}\treceipt.json\n'.encode())
    commit = git('-c', 'user.name=Hotaru release CI', '-c',
                 'user.email=41898282+github-actions[bot]@users.noreply.github.com',
                 'commit-tree', tree, *parents, input=f'chore(release): record {phase}\n'.encode())
    git('push', 'origin', f'{commit}:{ref}')
    print(json.dumps(receipt, indent=2))


if __name__ == '__main__':
    main()
