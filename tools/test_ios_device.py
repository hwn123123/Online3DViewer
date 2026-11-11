#!/usr/bin/env python3
"""Launch bundled models on a connected iPhone and collect native results."""
import argparse
import json
from pathlib import Path
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--device', required=True)
    parser.add_argument('--documents', nargs='+', help='Open filenames already in the app Documents directory')
    parser.add_argument('--timeout', type=int, default=90)
    parser.add_argument('--samples', nargs='+', default=[
        'RhinoLogo.3dm', 'as1_pe_203.stp', 'haus.ifc', 'Y_Bot.fbx', 'utah_teapot.stl', 'DamagedHelmet.glb'
    ])
    args = parser.parse_args()
    output = ROOT / 'build' / 'ios' / 'device-tests'
    output.mkdir(parents=True, exist_ok=True)
    results_file = output / ('results-documents.json' if args.documents else 'results.json')
    results = []
    for sample in args.documents or args.samples:
        print(f'Testing on iPhone: {sample}', flush=True)
        test_run = '--test-run=' + str(uuid.uuid4())
        subprocess.run(['xcrun', 'devicectl', 'device', 'process', 'launch', '--device', args.device,
                        '--terminate-existing', 'com.hwn.Online3DViewer', '--',
                        ('--document=' if args.documents else '--sample=') + sample, test_run],
                       capture_output=True, text=True, check=True, timeout=30)
        status_file = output / (sample + '.json')
        deadline = time.monotonic() + args.timeout
        status = {}
        while time.monotonic() < deadline:
            status_file.unlink(missing_ok=True)
            transfer = subprocess.run(['xcrun', 'devicectl', 'device', 'copy', 'from', '--device', args.device,
                                       '--domain-type', 'appDataContainer', '--domain-identifier', 'com.hwn.Online3DViewer',
                                       '--source', 'Library/Caches/viewer-status.json', '--destination', str(status_file)],
                                      capture_output=True, timeout=15)
            if transfer.returncode == 0 and status_file.exists():
                status = json.loads(status_file.read_text())
                if status.get('testRun') != test_run:
                    time.sleep(1)
                    continue
                if status.get('event') == 'model_loaded' and status.get('name') == sample:
                    break
                if status.get('event') in ('javascript_error', 'native_read_error', 'webcontent_terminated'):
                    break
            time.sleep(1)
        passed = status.get('testRun') == test_run and status.get('event') == 'model_loaded' and status.get('name') == sample
        details = status.get('details', {})
        if details.get('stream'):
            passed = passed and details.get('unsupportedCount') == 0 and details.get('displayed') == details.get('objectCount')
        screenshot = output / (sample + '.png')
        subprocess.run(['xcrun', 'devicectl', 'device', 'capture', 'screenshot', '--device', args.device,
                        '--destination', str(screenshot)], capture_output=True, timeout=15)
        result = {'sample': sample, 'passed': passed, 'state': status, 'screenshot': str(screenshot.relative_to(ROOT))}
        results.append(result)
        results_file.write_text(json.dumps(results, ensure_ascii=False, indent=2) + '\n')
        print(json.dumps(result, ensure_ascii=False), flush=True)
    if not all(result['passed'] for result in results):
        raise SystemExit(1)


if __name__ == '__main__':
    main()
