#!/usr/bin/env python3
"""Check batched 3DM geometry, selection ranges and failure cleanup independently."""
import json
import math
from pathlib import Path
import shutil
import struct
import subprocess

ROOT = Path(__file__).resolve().parent.parent
BASE = ROOT / 'build/ios/navigation-refresh-fix'
CLI = BASE / 'batch-cli'


def decode(path):
    data = path.read_bytes()
    h = struct.unpack_from('<8I', data)
    assert h[:2] == (0x3144334f, 1)
    v, ni, nl, colored = h[2:6]
    pos = list(struct.iter_unpack('<3f', data[32:32 + v * 12]))
    normals = list(struct.iter_unpack('<3f', data[32 + v * 12:32 + v * 24]))
    indices = list(struct.unpack_from('<' + str(ni) + 'I', data, 32 + v * 24))
    off = 32 + v * 24 + ni * 4
    lines = list(struct.iter_unpack('<3f', data[off:off + nl * 12]))
    colors = list(struct.iter_unpack('<3f', data[off + nl * 12:])) if colored else []
    return pos, normals, indices, lines, colors


def make_fixture(directory):
    shutil.rmtree(directory, ignore_errors=True)
    directory.mkdir(parents=True)
    items = []
    positions = [(0., 0., 0.), (1., 0., 0.), (0., 1., 0.)]
    normals = [(0., 0., 1.)] * 3
    line = [(0., 0., 0.), (1., 1., 0.)]
    for i in range(1100):
        colored = i < 800
        origin = [1_000_000_000.0 + (i % 100) * 1.2, (i // 100) * 1.2, 10.]
        suffix = b''.join(struct.pack('<3f', *p) for p in positions + normals)
        suffix += struct.pack('<3I', 0, 1, 2) + b''.join(struct.pack('<3f', *p) for p in line)
        if colored:
            suffix += b''.join(struct.pack('<3f', .25, .5, .75) for _ in positions)
        data = struct.pack('<8I', 0x3144334f, 1, 3, 3, 2, colored, 0, 0) + suffix
        name = f'object-{i:06d}.bin'
        (directory / name).write_bytes(data)
        item = {'id': f'source-{i}', 'index': i, 'name': f'part {i}', 'type': 'Mesh', 'layerIndex': 0 if i < 900 else 1,
                'materialIndex': 0, 'color': [1, 1, 1], 'lineColor': [.5, .5, .5], 'opacity': 1,
                'visible': True, 'definitionMember': False, 'available': True, 'origin': origin,
                'bounds': [*origin, origin[0] + 1, origin[1] + 1, origin[2]], 'url': name, 'bytes': len(data),
                'vertices': 3, 'triangles': 1, 'lineSegments': 1}
        if i == 1097: item['opacity'] = .5
        if i == 1098: item['visible'] = False
        if i == 1099: item['transform'] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 3, 4, 5, 1]
        items.append(item)
    manifest = {'format': 'o3dv-stream-1', 'reader': 'opennurbs-instances-1', 'complete': True,
                'name': 'Batch verification', 'objects': items, 'objectCount': len(items),
                'sourceObjectCount': len(items), 'geometryBytes': sum(x['bytes'] for x in items),
                'triangles': len(items), 'lineSegments': len(items), 'vertices': 3 * len(items),
                'layers': [{'index': i, 'id': f'layer-{i}', 'name': f'Layer {i}', 'visible': True} for i in range(2)],
                'materials': [], 'unsupported': [], 'bounds': [1_000_000_000., 0, 10, 1_000_000_119.8, 13, 10]}
    (directory / 'manifest.json').write_text(json.dumps(manifest))
    return manifest


def check_originals(source, target, before):
    result = json.loads((target / 'manifest.json').read_text())
    assert result['batchingVersion'] == 1 and result['sourceObjectCount'] == before['sourceObjectCount']
    assert result['triangles'] == before['triangles'] and result['lineSegments'] == before['lineSegments']
    assert result['objectCount'] == len(result['objects']) and len(result['objects']) < 30
    originals = {item['id']: item for item in before['objects']}
    seen = set()
    for out in result['objects']:
        pos, normals, idx, lines, colors = decode(target / out['url'])
        assert (target / out['url']).stat().st_size == out['bytes']
        for part in out.get('parts', [out]):
            old = originals[part['id']]; assert part['id'] not in seen; seen.add(part['id'])
            for key in ['layerIndex', 'materialIndex', 'color', 'lineColor', 'opacity', 'visible']:
                assert out[key] == old[key], (part['id'], key)
            p, n, oi, ol, oc = decode(source / old['url'])
            if 'parts' not in out:
                assert (target / out['url']).read_bytes() == (source / old['url']).read_bytes()
                assert out.get('transform') == old.get('transform')
                continue
            selected = idx[part['start']:part['end']]
            assert len(selected) == len(oi)
            for old_index, new_index in zip(oi, selected):
                for a in range(3):
                    assert abs((p[old_index][a] + old['origin'][a]) - (pos[new_index][a] + out['origin'][a])) <= .00011
                    assert n[old_index][a] == normals[new_index][a]
                    if oc: assert oc[old_index][a] == colors[new_index][a]
            selected_lines = lines[part['lineStart']:part['lineEnd']]
            assert len(selected_lines) == len(ol)
            for a, b in zip(ol, selected_lines):
                assert all(abs((a[k] + old['origin'][k]) - (b[k] + out['origin'][k])) <= .00011 for k in range(3))
            assert part['name'] == old['name'] and part['type'] == old['type']
    assert seen == set(originals)


def main():
    source = BASE / 'synthetic-input'; target = BASE / 'synthetic-output'
    before = make_fixture(source)
    shutil.rmtree(target, ignore_errors=True)
    subprocess.run([str(CLI), str(source), str(target)], check=True)
    check_originals(source, target, before)
    failed = BASE / 'synthetic-cancelled';shutil.rmtree(failed, ignore_errors=True)
    import os
    result = subprocess.run([str(CLI), str(source), str(failed)], env={**os.environ, 'O3DV_TEST_CANCEL': '1'}, capture_output=True)
    assert result.returncode and not failed.exists()
    damaged = source / before['objects'][10]['url'];original = damaged.read_bytes();damaged.write_bytes(original[:-1])
    failed = BASE / 'synthetic-damaged';shutil.rmtree(failed, ignore_errors=True)
    result = subprocess.run([str(CLI), str(source), str(failed)], capture_output=True)
    assert result.returncode and not failed.exists()
    damaged.write_bytes(original)
    assert json.loads((source / 'manifest.json').read_text()) == before
    print('PASS 1100 objects: all source geometry, color, layers, visibility, picking ranges, transforms, cancellation and corrupt-cache cleanup')


if __name__ == '__main__': main()
