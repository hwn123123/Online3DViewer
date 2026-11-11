#!/usr/bin/env python3
"""Compare every vertex, index, normal, color, line and object in two caches."""
import argparse
import json
from pathlib import Path
import struct
import numpy as np


def geometry(path):
    data = path.read_bytes()
    h = struct.unpack_from('<8I', data)
    assert h[0] == 0x3144334f and h[1] == 1 and not h[6] and not h[7]
    n, ni, nl, has_colors = h[2:6]
    positions = np.frombuffer(data, '<f4', n * 3, 32).reshape(n, 3)
    normals = np.frombuffer(data, '<f4', n * 3, 32 + n * 12).reshape(n, 3)
    indices = np.frombuffer(data, '<u4', ni, 32 + n * 24)
    offset = 32 + n * 24 + ni * 4
    lines = np.frombuffer(data, '<f4', nl * 3, offset).reshape(nl, 3)
    colors = np.frombuffer(data, '<f4', n * 3, offset + nl * 12).reshape(n, 3) if has_colors else None
    return positions, normals, indices, lines, colors


def main():
    parser = argparse.ArgumentParser();parser.add_argument('original', type=Path);parser.add_argument('batched', type=Path);args = parser.parse_args()
    old = json.loads((args.original / 'manifest.json').read_text())
    new = json.loads((args.batched / 'manifest.json').read_text())
    originals = {o['id']: o for o in old['objects']};seen = set();max_error = 0.;parts_count = 0
    assert len(originals) == len(old['objects'])
    for item in new['objects']:
        path = args.batched / item['url'];assert path.stat().st_size == item['bytes']
        if 'parts' not in item:
            source = originals[item['id']];assert item['id'] not in seen;seen.add(item['id'])
            assert path.read_bytes() == (args.original / source['url']).read_bytes()
            for k in ['origin', 'bounds', 'color', 'lineColor', 'layerIndex', 'materialIndex', 'opacity', 'visible', 'transform']:
                assert item.get(k) == source.get(k), (item['id'], k)
            continue
        pos, normals, indices, lines, colors = geometry(path);vertex_base = 0
        for part in item['parts']:
            source = originals[part['id']];assert part['id'] not in seen;seen.add(part['id']);parts_count += 1
            p, n, ind, line, col = geometry(args.original / source['url'])
            v = len(p)
            assert np.array_equal(n, normals[vertex_base:vertex_base+v])
            assert np.array_equal(ind + vertex_base, indices[part['start']:part['end']])
            assert (col is None and colors is None) or np.array_equal(col, colors[vertex_base:vertex_base+v])
            for a, b in [(p, pos[vertex_base:vertex_base+v]), (line, lines[part['lineStart']:part['lineEnd']])]:
                if len(a):
                    delta = np.abs(a.astype('f8') + np.array(source['origin']) - b.astype('f8') - np.array(item['origin']))
                    max_error = max(max_error, float(delta.max()))
                    assert np.all(delta <= np.maximum(1e-4, np.abs(a.astype('f8')) * 1e-6) + 1e-9), (part['id'], delta.max())
            assert part['name'] == source['name'] and part['type'] == source['type']
            for k in ['layerIndex', 'materialIndex', 'color', 'lineColor', 'opacity', 'visible']:
                assert item[k] == source[k], (part['id'], k)
            vertex_base += v
        assert vertex_base == len(pos)
    assert seen == set(originals), (len(seen), len(originals))
    for key in ['sourceObjectCount', 'triangles', 'lineSegments', 'vertices', 'bounds', 'unsupported']:
        assert old.get(key) == new.get(key), key
    print(json.dumps({'sourceObjects': len(originals), 'outputObjects': len(new['objects']), 'batchedSourceObjects': parts_count,
                      'triangles': old['triangles'], 'lineSegments': old['lineSegments'], 'maxPositionError': max_error}, ensure_ascii=False, indent=2))


if __name__ == '__main__':main()
