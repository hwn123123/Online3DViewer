#!/usr/bin/env python3
"""Create known SKP scenes using the independent upstream Python writer (development only)."""
import json
from pathlib import Path
import struct
import sys
import zlib

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'build/ios/openskp-skp-src/packages/python/src'))
from openskp import create

BASE = ROOT / 'build/ios/skp-stream-tests/sources'
BASE.mkdir(parents=True, exist_ok=True)


def png(path, colors):
    def chunk(tag, data):
        return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', zlib.crc32(tag + data))
    raw = b''.join(b'\0' + bytes(colors[row * 6:row * 6 + 6]) for row in range(2))
    path.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 2, 2, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))


square = [(0, 0, 0), (100, 0, 0), (100, 100, 0), (0, 100, 0)]
b = create()
b.add_face(square)
b.save(str(BASE / 'basic.skp'))

png(BASE / 'a.png', [255, 0, 0, 0, 255, 0, 0, 255, 0, 255, 0, 0])
png(BASE / 'b.png', [0, 255, 0, 255, 0, 0, 255, 0, 0, 0, 255, 0])
b = create()
front = b.add_texture_material('Front', str(BASE / 'a.png'), applied_width=100, applied_height=100)
back = b.add_texture_material('Back', str(BASE / 'b.png'), applied_width=100, applied_height=100)
b.add_face(square, material=front, back_material=back)
b.save(str(BASE / 'two-sided.skp'))

b = create()
paint = b.add_texture_material('Inherited', str(BASE / 'a.png'), applied_width=100, applied_height=100)
with b.add_component_definition('SharedSquare') as component:
    component.add_face(square)
for i in range(12):
    b.add_instance(component, name='Placed ' + str(i), translation=(i * 120, 0, 0), material=paint,
                   matrix3x3=(-1, 0, 0, 0, 2, 0, 0, 0, 1) if i % 2 else None)
b.add_polyline([(0, -50, 0), (100, -50, 0), (100, -50, 30)])
b.save(str(BASE / 'instances-lines.skp'))

b = create()
off = b.add_layer('Off', hidden=True)
b.add_face(square, layer=off)
b.add_face([(x, y, z + 20) for x, y, z in square], hidden=True)
b.add_text('Explicit unsupported annotation', (0, 0, 30))
b.save(str(BASE / 'visibility.skp'))

b = create()
b.add_face(square, holes=[[(40, 40, 0), (60, 40, 0), (60, 60, 0), (40, 60, 0)]])
b.save(str(BASE / 'hole.skp'))

b = create()
for i in range(256):
    b.add_face([(x + i * 120, y, z) for x, y, z in square])
b.save(str(BASE / 'cancel-large.skp'))

data = (BASE / 'basic.skp').read_bytes()
(BASE / 'bad-header.skp').write_bytes(b'not a SketchUp file')
(BASE / 'truncated.skp').write_bytes(data[:len(data) // 2])
print(json.dumps({'sources': str(BASE), 'knownScenes': 5, 'negativeScenes': 2}))
