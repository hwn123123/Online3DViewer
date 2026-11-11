#!/usr/bin/env python3
"""Capture actual iPhone view progress during a low-budget navigation test."""
import argparse
import json
from pathlib import Path
import sys
import time
import uuid
import audit_work_models as audit

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / 'build/ios/memory-recovery-tests'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--device', required=True)
    parser.add_argument('--item', required=True)
    args = parser.parse_args()
    run = '--test-run=memory-status-' + str(uuid.uuid4())
    audit.launch(args, ['--library-item='+args.item, '--ui-test-geometry-budget=25165824', '--benchmark-navigation', run])
    progress = None
    deadline = time.monotonic()+180
    while time.monotonic()<deadline:
        state = audit.read_status(args, 'Library/Caches/viewer-status.json', OUTPUT/'phone-progress-live.json')
        if state and state.get('testRun') == run and state.get('event') == 'stream_view_progress':
            details = state.get('details', {})
            if not details.get('complete') and details.get('previousFrameVisible'):
                progress = state
                audit.device(args, 'capture', 'screenshot', '--destination', str(OUTPUT/'phone-progress.png'), timeout=20)
                break
        time.sleep(.1)
    assert progress, 'No partial view progress was captured'
    details = progress['details']
    assert 0 <= details['visibleDone'] <= details['visibleTotal'] and details['geometryBudgetBytes'] <= 25165824, details
    (OUTPUT/'phone-progress.json').write_text(json.dumps(progress, ensure_ascii=False, indent=2)+'\n')
    for _ in range(120):
        done = audit.read_status(args, 'Library/Caches/navigation-benchmark.json', OUTPUT/'phone-benchmark.json')
        if done and done.get('testRun') == run and done.get('event') == 'navigation_benchmark_complete':
            assert all(x['complete'] for x in done['details']['results']), done
            print('PASS low-budget progress, previous frame retained, and complete navigation', flush=True)
            return
        time.sleep(.5)
    raise RuntimeError('Navigation benchmark timed out')


if __name__ == '__main__': main()
