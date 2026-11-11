#!/usr/bin/env python3
"""Exercise the read-only Git provenance tool against disposable Git checkouts."""
from pathlib import Path
import json, os, shutil, subprocess, sys, tempfile

root = next(p for p in Path(__file__).resolve().parents if (p/'tools/capture-source-revisions.py').exists())
script = root/'tools/capture-source-revisions.py'
assert script.exists()
if not shutil.which('git'):
    print('SKIP: no git installed; source provenance integration requires git')
    raise SystemExit(0)
with tempfile.TemporaryDirectory(prefix='3ds-openemu-provenance-') as tmp:
    temp = Path(tmp)
    a, o = temp/'azahar', temp/'openemu'
    cmd = [sys.executable, str(script), '--azahar-source', str(a),
           '--openemu-source', str(o), '--strict']
    absent = subprocess.run(cmd, capture_output=True, text=True)
    assert absent.returncode == 2
    for p in (a,o):
        p.mkdir()
        subprocess.run(['git', '-C', str(p), 'init', '-q'], check=True)
        (p/'marker.txt').write_text('source marker\n')
        subprocess.run(['git', '-C', str(p), 'add', 'marker.txt'], check=True)
        env=os.environ.copy()
        env.update({'GIT_AUTHOR_NAME':'Test', 'GIT_AUTHOR_EMAIL':'test@example.invalid',
                    'GIT_COMMITTER_NAME':'Test','GIT_COMMITTER_EMAIL':'test@example.invalid'})
        subprocess.run(['git', '-C', str(p), 'commit', '-qm', 'test'], check=True, env=env)
    found = subprocess.run(cmd, capture_output=True, text=True)
    assert found.returncode == 0,found.stderr
    assert str(temp) not in found.stdout # Never leak developer absolute paths
    payload = json.loads(found.stdout)
    for label in ('azahar','openemu'):
        repo=payload['upstream'][label]
        assert repo['available'] and len(repo['commit'])==40
        assert repo['dirty'] is False and repo['changed_paths']==0
    (a/'marker.txt').write_text('changed\n')
    changed=subprocess.run(cmd, capture_output=True, text=True)
    assert changed.returncode==0
    assert json.loads(changed.stdout)['upstream']['azahar']['dirty'] is True
    assert (a/'marker.txt').read_text()=='changed\n' # No hidden modification
print('SOURCE PROVENANCE READONLY + MISSING/VALID/DIRTY GIT PASS')
