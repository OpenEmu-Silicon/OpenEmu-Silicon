#!/usr/bin/env python3
"""Run maintained portable source/manifest regression tests (not an Xcode build).

Usage: python3 tools/run-source-checks.py
No network, original sources or local data are accessed. Build outputs are
placed in a temporary directory. The tests are intentionally offline and
cannot substitute for a real Apple Silicon macOS build and OpenEmu playtest.
"""
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def main():
    root = Path(__file__).resolve().parents[1]
    core = (root/'azcore').is_dir()
    tests = root/'azcore/tests' if core else root/'tests'
    pys = sorted(tests.glob('v*_test.py')) + sorted(tests.glob('v*_audit.py'))
    cpp = sorted(tests.glob('v*_test.cpp'))
    compiler = shutil.which('c++') or shutil.which('clang++') or shutil.which('g++')
    if not pys or (cpp and not compiler):
        print('FAIL: tests missing or C++ compiler unavailable', file=sys.stderr)
        return 2
    failures = 0
    with tempfile.TemporaryDirectory(prefix='3ds-openemu-check-') as temp:
        for path in pys:
            command = [sys.executable, str(path)]
            result = subprocess.run(command, cwd=root, capture_output=True, text=True)
            print(f"{'PASS' if result.returncode == 0 else 'FAIL'} {path.name}")
            if result.returncode:
                failures += 1
                print(result.stdout[-4000:] + result.stderr[-4000:], file=sys.stderr)
        for path in cpp:
            executable = Path(temp)/path.stem
            build = subprocess.run([compiler, '-std=c++17', '-O0', str(path), '-o', str(executable)],
                                   cwd=root, capture_output=True, text=True)
            if build.returncode:
                print(f'FAIL {path.name} compilation: {build.stderr[-4000:]}', file=sys.stderr)
                failures += 1
                continue
            result = subprocess.run([str(executable)], capture_output=True, text=True)
            print(f"{'PASS' if result.returncode == 0 else 'FAIL'} {path.name}")
            if result.returncode:
                failures += 1
                print(result.stdout[-4000:] + result.stderr[-4000:], file=sys.stderr)
    print(f"{'PASS' if failures == 0 else 'FAIL'} portable_regression_tests failures={failures}")
    return 0 if failures == 0 else 1


if __name__ == '__main__':
    raise SystemExit(main())
