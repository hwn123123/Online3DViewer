#!/usr/bin/env python3
"""Check native OBJ geometry against independent source-file statistics."""
import argparse
import json
import math
import os
from pathlib import Path
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def source_stats(path):
    triangles = lines = 0
    positions, faces = [], []
    for raw in path.read_text().splitlines():
        values = raw.split('#')[0].split()
        if not values:
            continue
        if values[0] == 'v':
            x, y, z = map(float, values[1:4])
            positions.append((x, -z, y))  # OBJ Y-up -> native Z-up.
        elif values[0] == 'f':
            triangles += len(values) - 3
            indices = [int(v.split('/')[0]) for v in values[1:]]
            indices = [v - 1 if v > 0 else len(positions) + v for v in indices]
            for i in range(1, len(indices) - 1):
                faces.append([positions[indices[k]] for k in [0, i, i + 1]])
        elif values[0] == 'l':
            lines += len(values) - 2
    return triangles, lines, faces


def area_moments(faces):
    result = [0.0] * 4
    for a, b, c in faces:
        u = [b[i] - a[i] for i in range(3)]
        v = [c[i] - a[i] for i in range(3)]
        cross = [u[1]*v[2]-u[2]*v[1], u[2]*v[0]-u[0]*v[2], u[0]*v[1]-u[1]*v[0]]
        area = math.sqrt(sum(x*x for x in cross)) / 2
        result[0] += area
        for i in range(3):
            result[i+1] += area * (a[i] + b[i] + c[i]) / 3
    return result


def check_blocks(directory):
    manifest = json.loads((directory / 'manifest.json').read_text())
    assert manifest['complete'] and not manifest['unsupported']
    faces, triangles, lines = [], 0, 0
    for item in manifest['objects']:
        data = (directory / item['url']).read_bytes()
        magic, version, count, index_count, line_count, colors, uvs, _ = struct.unpack_from('<8I', data)
        assert magic == 0x3144334f and version == 2
        assert len(data) == 32 + count*24 + index_count*4 + line_count*12 + colors*count*12 + uvs*count*8
        vertices = list(struct.iter_unpack('<3f', data[32:32+count*12]))
        indices = struct.unpack_from(f'<{index_count}I', data, 32+count*24)
        assert all(v < count for v in indices)
        assert all(math.isfinite(x) for v in vertices for x in v)
        world = [tuple(v[k]+item['origin'][k] for k in range(3)) for v in vertices]
        for i in range(0, index_count, 3):
            faces.append([world[indices[i+k]] for k in range(3)])
        triangles += index_count//3
        lines += line_count//2
        assert sum(p['end']-p['start'] for p in item['parts']) == index_count
        assert sum(p['lineEnd']-p['lineStart'] for p in item['parts']) == line_count
    assert triangles == manifest['triangles'] and lines == manifest['lineSegments']
    return manifest, faces


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--cli', type=Path, default=ROOT / 'build/ios/mesh-stream')
    args = parser.parse_args()
    fixtures = ROOT / 'test/testfiles/obj'
    names = ['single_triangle.obj', 'single_triangle_negative_indices.obj', 'single_rectangle.obj',
             'two_triangles.obj', 'two_triangles_in_meshes.obj', 'cube_rgb.obj', 'cube_with_edges.obj',
             'lines.obj', 'rectangle_with_texture.obj', 'two_materials_same_texture.obj']
    with tempfile.TemporaryDirectory(prefix='mesh-stream-test-') as temporary:
        root = Path(temporary)
        for name in names:
            output = root / name
            result = subprocess.run([str(args.cli), str(fixtures/name), str(output)], capture_output=True, text=True)
            assert result.returncode == 0, (name, result.stderr)
            manifest, faces = check_blocks(output)
            expected_triangles, expected_lines, expected_faces = source_stats(fixtures/name)
            assert manifest['triangles'] == expected_triangles, name
            assert manifest['lineSegments'] == expected_lines, name
            for actual, expected in zip(area_moments(faces), area_moments(expected_faces)):
                assert math.isclose(actual, expected, rel_tol=1e-5, abs_tol=1e-5), (name, actual, expected)
            print('PASS geometry, bounds, area and ranges:', name)
        textured = json.loads((root/'rectangle_with_texture.obj/manifest.json').read_text())
        assert any(m['texture'] and (root/'rectangle_with_texture.obj'/m['texture']['url']).exists() for m in textured['materials'])
        cancelled = subprocess.run([str(args.cli), str(fixtures/names[0]), str(root/'cancelled')],
                                   env={**os.environ, 'O3DV_TEST_CANCEL': '1'}, capture_output=True, text=True)
        assert cancelled.returncode == 1 and '取消' in cancelled.stderr
        invalid = root/'invalid.fbx'; invalid.write_bytes(b'Kaydara FBX Binary  \0\x1a\0\0')
        broken = subprocess.run([str(args.cli), str(invalid), str(root/'invalid-cache')], capture_output=True)
        assert broken.returncode == 1, broken
        print('PASS textures, cancellation and malformed-file error lifetime')
        # This upstream fixture references vt entries that are absent. Rejecting it must be safe.
        invalid_uv = subprocess.run([str(args.cli), str(fixtures/'lines_with_vt.obj'), str(root/'invalid-uv')], capture_output=True)
        assert invalid_uv.returncode == 1


if __name__ == '__main__':
    main()
