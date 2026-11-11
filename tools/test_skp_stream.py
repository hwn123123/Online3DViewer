#!/usr/bin/env python3
"""Validate native SKP geometry against authored shapes, then inspect real work files."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import time
import numpy as np

ROOT = Path(__file__).resolve().parent.parent
BASE = ROOT / 'build/ios/skp-stream-tests'
EXECUTABLE = ROOT / 'build/ios/skp-stream'


def run(source, cache, environment=None, expected=0):
    start = time.monotonic()
    result = subprocess.run([str(EXECUTABLE), str(source), str(cache)],
                            capture_output=True, text=True, timeout=300,
                            env={**os.environ, **(environment or {})})
    assert result.returncode == expected, (source, result.stdout[-1500:], result.stderr)
    if expected:
        assert not cache.exists(), ('unfinished cache left behind', cache)
        return {'code': result.returncode, 'error': result.stderr.strip()}
    manifest = json.loads((cache / 'manifest.json').read_text())
    assert manifest['complete'] and manifest['objectCount'] == len(manifest['objects'])
    assert manifest['reader'] == 'skp-stream-1'
    for part in manifest['objects']:
        assert (cache / part['url']).stat().st_size == part['bytes']
    return manifest, round(time.monotonic() - start, 3)


def geometry(cache, manifest):
    area = 0.
    lines = 0
    bounds = []
    for part in manifest['objects']:
        data = (cache / part['url']).read_bytes()
        magic, version, count, indices, line_count, colors, uvs, tangents = struct.unpack_from('<8I', data)
        assert magic == 0x3144334f and version == 3
        assert not colors and not tangents
        matrix = np.array(part['transform']).reshape(4, 4).T
        origin = np.array(part['origin'])
        if count:
            position = np.frombuffer(data, '<f4', count * 3, 32).reshape(-1, 3).astype('float64') + origin
            normal = np.frombuffer(data, '<f4', count * 3, 32 + count * 12).reshape(-1, 3)
            index = np.frombuffer(data, '<u4', indices, 32 + count * 24)
            assert (index < count).all() and np.isfinite(position).all()
            assert np.max(np.abs(np.linalg.norm(normal, axis=1) - 1)) < 1e-5
            world = position @ matrix[:3, :3].T + matrix[:3, 3]
            triangle = world[index].reshape(-1, 3, 3)
            area += np.linalg.norm(np.cross(triangle[:, 1] - triangle[:, 0], triangle[:, 2] - triangle[:, 0]), axis=1).sum() / 2
            bounds.append(world)
        if line_count:
            lines += line_count // 2
            position = np.frombuffer(data, '<f4', line_count * 3, 32).reshape(-1, 3).astype('float64') + origin
            bounds.append(position @ matrix[:3, :3].T + matrix[:3, 3])
    points = np.concatenate(bounds)
    return float(area), lines, np.concatenate((points.min(axis=0), points.max(axis=0)))


def main():
    global EXECUTABLE
    parser = argparse.ArgumentParser()
    parser.add_argument('--work-files', action='store_true')
    parser.add_argument('--executable', type=Path, default=EXECUTABLE)
    parser.add_argument('--results', type=Path, default=BASE / 'fixture-results.json')
    args = parser.parse_args()
    EXECUTABLE = args.executable.resolve()
    rows = []
    expected = {'basic': (2, 0, 6.4516), 'two-sided': (4, 0, 12.9032),
                'instances-lines': (24, 2, 116.1288), 'visibility': (4, 0, 12.9032),
                'hole': (8, 0, 6.193536)}
    for name, (triangles, lines, area) in expected.items():
        cache = BASE / 'fixture-caches' / name
        m, seconds = run(BASE / 'sources' / (name + '.skp'), cache)
        actual_area, actual_lines, bounds = geometry(cache, m)
        assert m['triangles'] == triangles and m['lineSegments'] == lines == actual_lines
        assert abs(actual_area - area) < 1e-4, (name, actual_area, area)
        if name == 'two-sided':
            images = {mat['texture']['url'] for mat in m['materials'] if mat.get('texture')}
            assert len(images) == 2
            digests = {hashlib.sha256((cache / image).read_bytes()).hexdigest() for image in images}
            assert digests == {hashlib.sha256((BASE / 'sources' / image).read_bytes()).hexdigest() for image in ['a.png', 'b.png']}
        if name == 'instances-lines':
            meshes = [o for o in m['objects'] if o['drawMode'] == 'triangles']
            assert len(meshes) == 12 and len({o['url'] for o in meshes}) == 1
            assert any(mat.get('texture') for mat in m['materials'])
            assert np.max(np.abs(bounds - [0, -1.27, 0, 33.528, 5.08, .762])) < 1e-4, bounds
        if name == 'visibility':
            assert any(not layer['visible'] for layer in m['layers'])
            assert any(not o['visible'] for o in m['objects'])
            assert m['unsupported'] and m['warnings']
        rows.append({'name': name, 'seconds': seconds, 'triangles': triangles, 'lines': lines, 'area': actual_area})
        print('PASS authored', name, triangles, lines, flush=True)
    negative = []
    for name in ['bad-header', 'truncated']:
        negative.append(run(BASE / 'sources' / (name + '.skp'), BASE / 'negative' / name, expected=1))
    for label, environment in [('cancel-before', {'O3DV_TEST_CANCEL': '1'}),
                               ('cancel-decode', {'O3DV_TEST_CANCEL_DURING_DECODE': '1'}),
                               ('cancel-ready', {'O3DV_TEST_CANCEL_AFTER_READY': '1'}),
                               ('low-budget', {'O3DV_TEST_DECODER_BUDGET': '512'}),
                               ('critical-pressure', {'O3DV_TEST_CRITICAL_PRESSURE': '1'})]:
        source = BASE / 'sources' / ('basic.skp' if label != 'cancel-decode' else 'cancel-large.skp')
        negative.append(run(source, BASE / 'negative' / label, environment, expected=1))
        print('PASS recovery', label, flush=True)
    if args.work_files:
        work = sorted([r for r in json.loads((ROOT / 'build/ios/work-model-tests/inventory.json').read_text()) if r['format'] == 'skp'], key=lambda r: r['bytes'])
        results = []
        for i, source in enumerate(work):
            cache = BASE / 'caches' / f'{i:02d}'
            m, seconds = run(Path(source['path']), cache)
            metrics = {k: m.get(k) for k in ['complete', 'objectCount', 'sourceObjectCount', 'triangles', 'lineSegments', 'geometryBytes', 'skpPeakAllocationBytes', 'skpWorkspaceDiskBytes', 'nativePeakFootprintBytes', 'nativePeakMemoryBytes', 'bounds', 'sketchupVersion']}
            results.append({'path': source['path'], 'cache': str(cache.relative_to(ROOT)), 'returncode': 0, 'elapsed': seconds, 'metrics': metrics, 'warnings': m['warnings'], 'unsupported': m['unsupported']})
            (BASE / 'native-results.json').write_text(json.dumps(results, ensure_ascii=False, indent=2) + '\n')
            print('PASS work', Path(source['path']).name, metrics['triangles'], flush=True)
    args.results.write_text(json.dumps({'passed': True, 'authored': rows, 'negative': negative}, ensure_ascii=False, indent=2) + '\n')


if __name__ == '__main__':
    main()
