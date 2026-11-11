#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Verify 3D CAD leaders, arrows, block placement and DWG encodings."""
import json
import os
from pathlib import Path
import subprocess
import numpy as np
import test_cad_stream as cad

ROOT = cad.ROOT
BASE = ROOT / 'build/ios/cad-leader-tests'
SOURCES = BASE / 'sources'
CLI = ROOT / 'build/ios/cad-text-stream'
POINTS = [(1, 2, 3), (4, 2, 7), (8, 2, 7)]


def leader(arrow, spline=False, normal=(0, 1, 0), color=None):
    pairs = [(0, 'LEADER'), (5, '500'), (8, '0'), (3, 'Standard'), (71, int(arrow)),
             (72, int(spline)), (73, 3), (74, 0), (75, 0), (76, len(POINTS)),
             (210, normal[0]), (220, normal[1]), (230, normal[2])]
    for x, y, z in POINTS: pairs += [(10, x), (20, y), (30, z)]
    if color is not None: pairs.append((77, color))
    return pairs


def run(source, name, env=None, expected=0):
    cache = BASE / 'caches' / name
    result = subprocess.run([str(CLI), str(source), str(cache)], capture_output=True, text=True,
                            env={**os.environ, **(env or {})}, timeout=180)
    assert result.returncode == expected, (source, result.stdout[-500:], result.stderr[-1000:])
    if expected:
        assert not cache.exists();return None
    manifest = json.loads((cache / 'manifest.json').read_text())
    assert manifest['complete'] and manifest['reader'] == 'cad-stream-4'
    return manifest, cad.geometry(cache, manifest)


def main():
    SOURCES.mkdir(parents=True, exist_ok=True)
    cad.drawing(SOURCES/'straight.dxf', leader(False))
    cad.drawing(SOURCES/'arrow.dxf', leader(True))
    cad.drawing(SOURCES/'spline.dxf', leader(False, True))
    cad.drawing(SOURCES/'color.dxf', leader(False, color=1))
    cad.drawing(SOURCES/'style-color.dxf', leader(False, color=1))
    cad.drawing(SOURCES/'custom-arrow.dxf', leader(True))
    for name, extra in [('style-color', [(176, 2)]), ('custom-arrow', [(341, 'AB')])]:
        path = SOURCES / (name + '.dxf')
        table = [(0, 'TABLE'), (2, 'DIMSTYLE'), (70, 1), (0, 'DIMSTYLE'), (105, '24'),
                 (2, 'Standard'), (70, 0), *extra, (0, 'ENDTAB')]
        insert = ''.join(f'{code}\n{value}\n' for code, value in table)
        path.write_text(path.read_text().replace('0\nTABLE\n2\nBLOCK_RECORD\n', insert + '0\nTABLE\n2\nBLOCK_RECORD\n'))
    cad.drawing(SOURCES/'block.dxf', cad.insert('600', 'LEADER_BLOCK', (10, 20, 30), (2, 2, 2), 90),
                [('30', 'LEADER_BLOCK', (0, 0, 0), leader(False))])
    plain, (lines, tris) = run(SOURCES/'straight.dxf', 'straight')
    assert not len(tris) and len(lines) == 2 and np.max(np.abs(lines - np.array([POINTS[:2], POINTS[1:]]))) < 1e-6
    assert not any(x['type'] == 'LEADER' for x in plain['unsupported'])
    colored, _ = run(SOURCES/'color.dxf', 'color')
    assert all(o['color'] == [1, 0, 0] for o in colored['objects'])
    colored, _ = run(SOURCES/'style-color.dxf', 'style-color')
    assert all(o['color'] == [1, 1, 0] for o in colored['objects'])
    custom, (custom_lines, custom_triangles) = run(SOURCES/'custom-arrow.dxf', 'custom-arrow')
    assert len(custom_lines) == 2 and not len(custom_triangles)
    assert any(x['type'] == '自定义引线箭头' for x in custom['unsupported'])
    arrow, (lines, tris) = run(SOURCES/'arrow.dxf', 'arrow')
    assert len(tris) == 1 and len(lines) == 2
    assert np.max(np.abs(tris[0, 0] - POINTS[0])) < 1e-6 and np.max(np.abs(lines[0, 0] - (tris[0, 1] + tris[0, 2]) / 2)) < 1e-6
    assert np.max(np.abs(tris[:, :, 1] - 2)) < 1e-6 and np.linalg.norm(np.cross(tris[0, 1] - tris[0, 0], tris[0, 2] - tris[0, 0])) > 0
    spline, (curved, _) = run(SOURCES/'spline.dxf', 'spline')
    assert len(curved) > 2 and all(abs(p - 2) < 1e-6 for p in curved[:, :, 1].flat)
    assert any('样条引线' in warning for warning in spline['warnings'])
    _, (placed, _) = run(SOURCES/'block.dxf', 'block')
    expected = np.array([POINTS[:2], POINTS[1:]], dtype=float) * 2
    expected = expected @ np.array([[0, 1, 0], [-1, 0, 0], [0, 0, 1]]) + [10, 20, 30]
    assert np.max(np.abs(placed - expected)) < 1e-5, (placed, expected)
    for version in ['AC1015', 'AC1018', 'AC1021', 'AC1024', 'AC1027', 'AC1032']:
        target = SOURCES / (version + '.dwg')
        subprocess.run([str(cad.RUST/'cad-fixtures'), str(SOURCES/'straight.dxf'), str(target), version], check=True)
        state, (actual, _) = run(target, version)
        assert len(actual) == 2 and np.max(np.abs(actual - np.array([POINTS[:2], POINTS[1:]]))) < 1e-5, version
        assert not any(x['type'] == 'LEADER' for x in state['unsupported'])
    run(SOURCES/'arrow.dxf', 'cancelled', {'O3DV_TEST_CANCEL': '1'}, 1)
    run(SOURCES/'arrow.dxf', 'budget', {'O3DV_TEST_DECODER_BUDGET': '1'}, 1)
    rows = json.loads((ROOT/'build/ios/cad-text-tests/native-results.json').read_text())
    results = []
    for row in (r for r in rows if r.get('path')):
        source = Path(row['path']);before = source.stat();state, _ = run(source, row['cache']);after = source.stat()
        assert (before.st_size, before.st_mtime_ns) == (after.st_size, after.st_mtime_ns)
        results.append({'path': str(source), 'cache': row['cache'], 'lineSegments': state['lineSegments'],
                        'triangles': state['triangles'], 'unsupported': state['unsupported'], 'warnings': state['warnings']})
        print('PASS work', source.name, 'lines', state['lineSegments'], 'leader unsupported',
              sum(x['count'] for x in state['unsupported'] if x['type'] == 'LEADER'), flush=True)
    (BASE/'results.json').write_text(json.dumps(results, ensure_ascii=False, indent=2))
    print('PASS 3D leader coordinates, arrows, splines, nested blocks, six DWG versions and cleanup')


if __name__ == '__main__': main()
