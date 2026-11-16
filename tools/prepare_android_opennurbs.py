#!/usr/bin/env python3
"""Prepare the pinned openNURBS source used by the Android NDK build."""
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / 'build/ios/opennurbs-src'
REVISION = 'eb92af3ba1806b0a34a99aba0d3bda83e3d46083'


def main():
    if not SOURCE.exists():
        SOURCE.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(['git', 'clone', '--no-checkout', 'https://github.com/mcneel/opennurbs.git', str(SOURCE)], check=True)
        subprocess.run(['git', '-C', str(SOURCE), 'checkout', '--detach', REVISION], check=True)
    revision = subprocess.check_output(['git', '-C', str(SOURCE), 'rev-parse', 'HEAD'], text=True).strip()
    if revision != REVISION:
        raise SystemExit(f'Existing openNURBS source is at {revision}; expected {REVISION}. Preserve or move it before preparing the pinned source.')
    if subprocess.check_output(['git', '-C', str(SOURCE), 'status', '--porcelain', '--untracked-files=no'], text=True).strip():
        raise SystemExit('Existing openNURBS source has local changes; preserve them before building.')
    print(f'openNURBS {REVISION}: {SOURCE}')


if __name__ == '__main__':
    main()
