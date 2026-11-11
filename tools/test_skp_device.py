#!/usr/bin/env python3
"""Exercise real work SKPs and recovery through the installed iPhone app."""
import argparse
import json
from pathlib import Path
import test_stl_device as runner

ROOT = Path(__file__).resolve().parent.parent
BASE = ROOT / 'build/ios/skp-stream-tests'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--device', required=True)
    parser.add_argument('--timeout', type=int, default=600)
    parser.add_argument('--only', type=int, nargs='+')
    parser.add_argument('--prepared-case6', help='Reuse an existing phone-generated cache for the largest SKP.')
    args = parser.parse_args()
    runner.OUTPUT = BASE / 'device'
    runner.OUTPUT.mkdir(parents=True, exist_ok=True)
    runner.CASE_PREFIX = '77777777-7777-4777-8777-'
    native = json.loads((BASE / 'native-results.json').read_text())
    cases = [(i + 1, Path(row['path']), 'model_loaded', row['metrics']['triangles'], {})
             for i, row in enumerate(native)]
    large = Path(native[-1]['path'])
    cases += [
        (7, large, 'load_cancelled', None, {'cancelAfterDecoderBytes': 4 * 1048576}),
        (8, large, 'resource_limit', None, {'decoderBudgetBytes': 512 * 1024}),
        (9, BASE / 'sources/bad-header.skp', 'native_read_error', None, {}),
        (10, BASE / 'sources/instances-lines.skp', 'model_loaded', 24, {}),
        (11, ROOT / 'test/testfiles/gltf/Box/glTF-Draco/Box.gltf', 'model_loaded', 12, {'companions': ['Box.bin']}),
        (12, ROOT / 'build/ios/WebAssets/assets/models/utah_teapot.stl', 'model_loaded', 9438, {}),
        (13, ROOT / 'build/ios/WebAssets/assets/models/RhinoLogo.3dm', 'model_loaded', None, {}),
        (14, BASE / 'sources/two-sided.skp', 'model_loaded', 4, {}),
        (15, BASE / 'sources/hole.skp', 'model_loaded', 8, {}),
    ]
    inventory = json.loads((ROOT / 'build/ios/work-model-tests/inventory.json').read_text())
    backup = next(row for row in inventory if row['format'] == 'skpbak')
    backup_manifest = json.loads((BASE / 'backup-cache/manifest.json').read_text())
    cases.append((16, Path(backup['path']), 'model_loaded', backup_manifest['triangles'], {}))
    output = runner.OUTPUT / 'results.json'
    results = json.loads(output.read_text()) if output.exists() else []
    for number, source, expected, triangles, settings in cases:
        if args.only and number not in args.only:
            continue
        if number == 6 and args.prepared_case6:
            settings['preparedCache'] = args.prepared_case6
        row = runner.run_case(args, number, source, expected, triangles, 8 * 1048576, **settings)
        if source.suffix.lower() in {'.skp', '.skpbak'} and expected == 'model_loaded':
            state = row['state']['details']
            assert state['reader'] == 'skp-stream-1', state
            assert state['triangles'] == triangles, state
            assert state['complete'] and state['displayed'] == state['objectCount'], state
        results = [r for r in results if r['number'] != number] + [row]
        output.write_text(json.dumps(sorted(results, key=lambda r: r['number']), ensure_ascii=False, indent=2) + '\n')


if __name__ == '__main__':
    main()
