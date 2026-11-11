#!/usr/bin/env python3
"""Exercise HATCH geometry, warnings, cache reuse and recovery on iPhone."""
import argparse
import json
from pathlib import Path
import test_stl_device as runner

ROOT = Path(__file__).resolve().parent.parent
BASE = ROOT / 'build/ios/hatch-tests'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--device', required=True)
    parser.add_argument('--timeout', type=int, default=300)
    parser.add_argument('--only', type=int, nargs='+')
    args = parser.parse_args()
    runner.OUTPUT = BASE / 'device'
    runner.OUTPUT.mkdir(parents=True, exist_ok=True)
    runner.CASE_PREFIX = '66666666-6666-4666-8666-'
    sources = BASE / 'sources'
    work = json.loads((BASE / 'results.json').read_text())
    cases = [(sources / (name + '.dxf'), 'model_loaded', name, {}) for name in
             ('solid-0', 'solid-1', 'solid-2', 'spline', 'plane', 'block', 'pattern-0', 'dense', 'dotted')]
    cases += [(Path(work[2]['path']), 'model_loaded', None, {}),
              (sources / 'solid-0.dxf', 'load_cancelled', None, {'cancelAfterReadBytes': 1}),
              (sources / 'solid-0.dxf', 'model_loaded', 'solid-0', {}),
              (ROOT / 'build/ios/WebAssets/assets/models/utah_teapot.stl', 'model_loaded', None, {})]
    results = []
    for number, (source, expected, reference, settings) in enumerate(cases, 1):
        if args.only and number not in args.only:
            continue
        triangles = 9438 if source.suffix == '.stl' else None
        row = runner.run_case(args, number, source, expected, triangles, 4 * 1048576, **settings)
        if expected == 'model_loaded' and source.suffix.lower() in ('.dwg', '.dxf'):
            phone = row['state']['details']
            assert phone['reader'] == 'cad-stream-4' and phone['complete'], phone
            assert phone['displayed'] == phone['objectCount'], phone
            if reference:
                original = json.loads((BASE / 'caches' / reference / 'manifest.json').read_text())
                assert phone['lineSegments'] == original['lineSegments'], phone
                assert phone['triangles'] == original['triangles'], phone
                if reference in ('dense', 'dotted'):
                    assert phone['unsupportedCount'] and not phone['coverageComplete'], phone
        results.append(row)
        (runner.OUTPUT / 'results.json').write_text(json.dumps(results, ensure_ascii=False, indent=2) + '\n')


if __name__ == '__main__':
    main()
