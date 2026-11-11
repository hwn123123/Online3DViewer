#!/usr/bin/env python3
"""Check the shared pager on iPhone with isolated STL, 3DM, glTF and CAD fixtures."""
import argparse
import json
from pathlib import Path
import test_stl_device as runner

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / 'build/ios/memory-recovery-tests/device'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--device', required=True)
    parser.add_argument('--timeout', type=int, default=240)
    args = parser.parse_args()
    runner.OUTPUT = OUTPUT
    OUTPUT.mkdir(parents=True, exist_ok=True)
    runner.CASE_PREFIX = '33333333-3333-4333-8333-'
    fixtures = [
        (2, ROOT/'test/testfiles/stl/cube_meshlab_ascii.stl', 12, {}),
        (3, ROOT/'build/ios/WebAssets/assets/models/utah_teapot.stl', 9438, {}),
        (4, ROOT/'build/ios/WebAssets/assets/models/RhinoLogo.3dm', None, {}),
        (5, ROOT/'test/testfiles/gltf/Box/glTF-Draco/Box.gltf', 12, {'companions':['Box.bin']}),
        (6, ROOT/'build/ios/hatch-tests/sources/pattern-0.dxf', None, {}),
        (7, ROOT/'build/ios/hatch-tests/sources/spline.dxf', None, {}),
    ]
    rows = []
    for number, source, triangles, settings in fixtures:
        row = runner.run_case(args, number, source, 'model_loaded', triangles, 4*1048576, **settings)
        details = row['state']['details']
        assert details['complete'] and details['displayed'] == details['objectCount'], details
        if source.suffix.lower() == '.dxf': assert details['reader'] == 'cad-stream-4', details
        rows.append(row)
        (OUTPUT/'results.json').write_text(json.dumps(rows, ensure_ascii=False, indent=2)+'\n')


if __name__ == '__main__':
    main()
