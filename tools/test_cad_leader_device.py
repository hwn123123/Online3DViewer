#!/usr/bin/env python3
"""Exercise LEADER display, coverage warnings and recovery on an iPhone."""
import argparse
import json
from pathlib import Path
import test_stl_device as runner

ROOT = Path(__file__).resolve().parent.parent
BASE = ROOT / 'build/ios/cad-leader-tests'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--device', required=True)
    parser.add_argument('--timeout', type=int, default=240)
    args = parser.parse_args()
    runner.OUTPUT = BASE / 'device'
    runner.OUTPUT.mkdir(parents=True, exist_ok=True)
    runner.CASE_PREFIX = '77777777-7777-4777-8777-'
    sources = BASE / 'sources'
    work = json.loads((BASE / 'results.json').read_text())
    cases = [(sources / (name + '.dxf'), 'model_loaded', name, {}) for name in
             ('straight', 'arrow', 'spline', 'block', 'custom-arrow', 'style-color')]
    cases += [(Path(work[2]['path']), 'model_loaded', None, {}),
              (sources / 'arrow.dxf', 'load_cancelled', None, {'cancelAfterReadBytes': 1}),
              (sources / 'arrow.dxf', 'model_loaded', 'arrow', {}),
              (ROOT / 'build/ios/WebAssets/assets/models/utah_teapot.stl', 'model_loaded', None, {})]
    results = []
    for number, (source, expected, reference, settings) in enumerate(cases, 1):
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
                if reference == 'spline':
                    assert any('样条引线' in warning for warning in phone['warnings']), phone
                if reference == 'custom-arrow':
                    assert phone['unsupportedCount'] and not phone['coverageComplete'], phone
        results.append(row)
        (runner.OUTPUT / 'results.json').write_text(json.dumps(results, ensure_ascii=False, indent=2) + '\n')


if __name__ == '__main__':
    main()
