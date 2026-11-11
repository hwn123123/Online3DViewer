#!/usr/bin/env python3
"""Independently compare source STL faces with bounded native-cache geometry."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import struct
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / 'build/ios/stl-stream-tests'


def source_faces(path):
    with path.open('rb') as source:
        header = source.read(84)
        if len(header) == 84 and path.stat().st_size == 84 + struct.unpack_from('<I', header, 80)[0]*50:
            while record := source.read(50):
                yield struct.unpack_from('<9f', record, 12)
            return
    # A separate, line-oriented reference reader; the production reader is token based.
    triangle = []
    with path.open(encoding='utf-8-sig') as source:
        for line in source:
            words = line.split('#', 1)[0].split()
            if words and words[0] == 'vertex':
                triangle.extend(map(float, words[1:4]))
            elif words and words[0] == 'endfacet':
                assert len(triangle) == 9, path
                yield tuple(triangle)
                triangle = []


def statistics(faces):
    count, area = 0, 0.0
    bounds = [math.inf]*3 + [-math.inf]*3
    digest = hashlib.sha256()
    for face in faces:
        count += 1
        digest.update(struct.pack('<9d', *face))
        for j in range(3):
            for k in range(3):
                bounds[k] = min(bounds[k], face[j*3+k])
                bounds[k+3] = max(bounds[k+3], face[j*3+k])
        u = [face[3+k]-face[k] for k in range(3)]
        v = [face[6+k]-face[k] for k in range(3)]
        cross = [u[1]*v[2]-u[2]*v[1], u[2]*v[0]-u[0]*v[2], u[0]*v[1]-u[1]*v[0]]
        area += math.sqrt(sum(x*x for x in cross))/2
    return {'triangles': count, 'bounds': bounds, 'area': area, 'orderedFaceSHA256': digest.hexdigest()}


def cache_faces(directory, check_normals=True):
    manifest = json.loads((directory/'manifest.json').read_text())
    assert manifest['complete'] and manifest['reader'] == 'stl-stream-1' and not manifest['unsupported']
    total_bytes = 0
    for block in manifest['objects']:
        data = (directory/block['url']).read_bytes()
        total_bytes += len(data)
        magic, version, vertices, indices, lines, colors, uvs, _ = struct.unpack_from('<8I', data)
        assert (magic, version, lines, colors, uvs) == (0x3144334f, 2, 0, 0, 0)
        assert indices == vertices == block['triangles']*3
        assert 0 < block['triangles'] <= manifest['maxBlockTriangles']
        assert len(data) == block['bytes'] == 32+vertices*24+indices*4
        points = list(struct.iter_unpack('<3f', data[32:32+vertices*12]))
        normals = list(struct.iter_unpack('<3f', data[32+vertices*12:32+vertices*24]))
        faces = struct.unpack_from(f'<{indices}I', data, 32+vertices*24)
        assert min(faces) >= 0 and max(faces) < vertices
        if check_normals:
            assert all(math.isfinite(x) for n in normals for x in n)
            assert all(math.isclose(sum(x*x for x in n), 1, abs_tol=1e-6) or sum(x*x for x in n) == 0 for n in normals)
        assert sum(p['end']-p['start'] for p in block['parts']) == indices
        for at in range(0, indices, 3):
            yield tuple(points[faces[at+j]][k]+block['origin'][k] for j in range(3) for k in range(3))
    assert total_bytes == manifest['geometryBytes']


def grid_face(i):
    x, y = i % 1024, i // 1024
    return (x, y, 0, x+0.75, y, 0, x+0.25, y+0.75, 0)


def binary(path, count, header=b'Generated bounded STL validation'):
    with path.open('wb') as out:
        out.write(header.ljust(80, b' ')[:80]);out.write(struct.pack('<I', count))
        buffer = bytearray()
        for i in range(count):
            buffer.extend(struct.pack('<12fH', 0, 0, 0, *grid_face(i), 0))
            if len(buffer) >= 1024*1024:
                out.write(buffer);buffer.clear()
        out.write(buffer)


def ascii_grid(path, count):
    with path.open('w') as out:
        out.write('solid grid\n')
        for i in range(count):
            face = grid_face(i)
            out.write('facet normal 0 0 0\nouter loop\n')
            for at in range(0, 9, 3):
                out.write('vertex '+' '.join(str(x) for x in face[at:at+3])+'\n')
            out.write('endloop\nendfacet\n')
        out.write('endsolid grid\n')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--cli', type=Path, default=ROOT/'build/ios/stl-stream')
    parser.add_argument('--large', action='store_true', help='Include 1,048,576 binary and 262,144 ASCII faces')
    parser.add_argument('--work-stl', type=Path, help='Optional local STL sample to compare')
    args = parser.parse_args()
    OUTPUT.mkdir(parents=True, exist_ok=True)
    sources = OUTPUT/'sources';sources.mkdir(exist_ok=True)
    paths = sorted((ROOT/'test/testfiles/stl').glob('*.stl'))
    paths.append(ROOT/'build/ios/WebAssets/assets/models/utah_teapot.stl')
    if args.work_stl: paths.append(args.work_stl)
    binary(sources/'solid-header.stl', 3, b'solid binary header is legal')
    binary(sources/'chunk-boundaries.stl', 32769)
    paths += [sources/'solid-header.stl', sources/'chunk-boundaries.stl']
    text = ('\ufeff# STL comment\nsolid 中文名称\nfacet\nouter loop\n'
            'vertex 1.0e14 0 0\nvertex 100000000000000.25 0 0\nvertex 100000000000000 0.5 0\n'
            'endloop\nendfacet\nendsolid 中文名称\nsolid Second\nfacet normal 0 0 -1\nouter loop\n'
            'vertex 0 0 2\nvertex 0 1 2\nvertex 1 0 2\nendloop\nendfacet\nendsolid Second\n')
    (sources/'multiple-solids.stl').write_text(text)
    paths.append(sources/'multiple-solids.stl')
    # A solid name cannot force unbounded allocation or prevent cooperative cancellation.
    (sources/'long-name.stl').write_text('solid '+('a'*2_000_000)+'\n'+
        (ROOT/'test/testfiles/stl/single_triangle.stl').read_text().split('\n', 1)[1])
    paths.append(sources/'long-name.stl')
    if args.large:
        binary(sources/'large-binary.stl', 1048576)
        ascii_grid(sources/'large-ascii.stl', 262144)
        paths += [sources/'large-binary.stl', sources/'large-ascii.stl']
    results = []
    for path in paths:
        directory = OUTPUT/'caches'/path.stem
        if directory.exists():shutil.rmtree(directory)
        start = time.monotonic()
        run = subprocess.run([str(args.cli), str(path), str(directory)], capture_output=True, text=True, timeout=180)
        assert run.returncode == 0, (path, run.stderr)
        elapsed = time.monotonic()-start
        actual, expected = statistics(cache_faces(directory)), statistics(source_faces(path))
        assert actual['triangles'] == expected['triangles'], path
        for a, b in zip(actual['bounds'], expected['bounds']):assert math.isclose(a, b, rel_tol=1e-7, abs_tol=1e-6), (path, a, b)
        assert math.isclose(actual['area'], expected['area'], rel_tol=1e-6, abs_tol=1e-6), (path, actual, expected)
        # Exact ordered-coordinate equality for synthetic fixtures; input binary coordinates are exactly representable.
        if path.parent == sources:assert actual['orderedFaceSHA256'] == expected['orderedFaceSHA256'], path
        manifest = json.loads((directory/'manifest.json').read_text())
        assert manifest['triangles'] == manifest['sourceTriangles'] == actual['triangles']
        progress = [json.loads(line) for line in run.stdout.splitlines()]
        assert progress[-1]['phase'] == 'complete' and progress[-1]['bytesRead'] == path.stat().st_size
        assert all(0 <= p['bytesRead'] <= p['sourceBytes'] for p in progress)
        assert [p['bytesRead'] for p in progress] == sorted(p['bytesRead'] for p in progress)
        row = {'name': path.name, 'sourceBytes': path.stat().st_size, 'seconds': round(elapsed, 3),
               **actual, 'blocks': manifest['objectCount'], 'sourceObjects': manifest['sourceObjectCount'],
               'nativePeakFootprintBytes': manifest['nativePeakFootprintBytes'],
               'geometryBufferCapacityBytes': manifest['geometryBufferCapacityBytes'],
               'progressReports': len(progress)}
        results.append(row)
        print('PASS', json.dumps(row, ensure_ascii=False), flush=True)
    assert json.loads((OUTPUT/'caches/multiple-solids/manifest.json').read_text())['sourceObjectCount'] == 2
    # Renaming an input changes names only; all block geometry must be identical.
    renamed = sources/'unrelated-name.stl';shutil.copyfile(sources/'chunk-boundaries.stl', renamed)
    rename_cache = OUTPUT/'renamed-cache'
    run = subprocess.run([str(args.cli), str(renamed), str(rename_cache)], capture_output=True)
    assert run.returncode == 0
    original = OUTPUT/'caches/chunk-boundaries'
    for p in original.glob('*.bin'):assert p.read_bytes() == (rename_cache/p.name).read_bytes()
    sample = (ROOT/'test/testfiles/stl/single_triangle.stl').read_bytes()
    binary_sample = (sources/'solid-header.stl').read_bytes()
    failures = {
        'empty': b'', 'truncated-binary': binary_sample[:-1], 'extra-binary-byte': binary_sample+b'\0',
        'bad-count': binary_sample[:80]+struct.pack('<I', 0xffffffff)+binary_sample[84:],
        'nonfinite-binary': binary_sample[:96]+struct.pack('<f', math.nan)+binary_sample[100:],
        'incomplete-facet': sample.replace(b'endfacet', b''),
        'missing-solid-end': sample.replace(b'endsolid MeshName', b''),
        'nonfinite-ascii': sample.replace(b'vertex 0.0', b'vertex nan', 1),
        'missing-vertex': sample.replace(b'vertex 1.0 1.0 0.0', b''),
        'extra-vertex': sample.replace(b'endloop', b'vertex 2 2 0\nendloop'),
        'not-a-model': b'this is not an STL model\n',
    }
    negatives = []
    for name, data in failures.items():
        path = sources/(name+'.stl');path.write_bytes(data)
        directory = OUTPUT/'negative-caches'/name
        run = subprocess.run([str(args.cli), str(path), str(directory)], capture_output=True, text=True)
        assert run.returncode == 1 and 'O3DVSTL:1' in run.stderr, (name, run)
        assert not (directory/'manifest.json').exists() or not json.loads((directory/'manifest.json').read_text())['complete']
        negatives.append({'name': name, 'error': run.stderr.strip()})
    for key, expected_code in [('CANCEL', 3), ('CANCEL_AFTER_READY', 3), ('CRITICAL_PRESSURE', 2)]:
        run = subprocess.run([str(args.cli), str(sources/'chunk-boundaries.stl'), str(OUTPUT/'negative-caches'/key)],
                             env={**os.environ, 'O3DV_TEST_'+key: '1'}, capture_output=True, text=True)
        assert run.returncode == 1 and f'O3DVSTL:{expected_code}' in run.stderr, (key, run)
        negatives.append({'name': key, 'error': run.stderr.strip()})
    if args.large:
        sizes = {r['name']: r for r in results}
        assert sizes['large-binary.stl']['nativePeakFootprintBytes'] < 64*1048576
        assert sizes['large-ascii.stl']['nativePeakFootprintBytes'] < 64*1048576
        assert sizes['large-binary.stl']['geometryBufferCapacityBytes'] == sizes['solid-header.stl']['geometryBufferCapacityBytes']
    (OUTPUT/'native-results.json').write_text(json.dumps({'passed': True, 'geometry': results, 'negative': negatives}, ensure_ascii=False, indent=2)+'\n')
    print(f'PASS {len(results)} geometry cases, rename equivalence and {len(negatives)} failure/cancel/resource cases')


if __name__ == '__main__':
    main()
