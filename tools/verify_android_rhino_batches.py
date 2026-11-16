#!/usr/bin/env python3
"""Compare object identity, styles and sampled 3DM geometry across two local caches."""
import argparse
import json
import math
import struct
from pathlib import Path


def block(path):
    raw=path.read_bytes()
    h=struct.unpack_from('<8I',raw)
    assert h[0]==0x3144334f and h[1]==1
    v,n,l,c=h[2:6]
    assert len(raw)==32+v*24+n*4+l*12+(v*12 if c else 0)
    return raw,h


def main():
    p=argparse.ArgumentParser();p.add_argument('--reference',type=Path,required=True);p.add_argument('--android',type=Path,required=True);p.add_argument('--samples',type=int,default=1000);args=p.parse_args()
    ref=json.loads((args.reference/'manifest.json').read_text());actual=json.loads((args.android/'manifest.json').read_text())
    assert ref['complete'] and actual['complete']
    for key in ('sourceObjectCount','triangles','vertices','lineSegments'):
        assert ref[key]==actual[key],(key,ref[key],actual[key])
    expected={x['id']:x for x in ref['objects']};seen=set();sampled=0
    stride=max(1,len(expected)//max(1,args.samples))
    for obj in actual['objects']:
        members=obj.get('parts') or [None]
        actual_raw=None;actual_header=None
        for part in members:
            ident=obj['id'] if part is None else part['id']
            assert ident in expected and ident not in seen,ident
            old=expected[ident];seen.add(ident)
            for key in ('layerIndex','materialIndex','color','lineColor','opacity','visible','definitionMember'):
                assert old.get(key)==obj.get(key),(ident,key,old.get(key),obj.get(key))
            if part is None:
                for key in ('triangles','vertices','lineSegments','bounds','origin'):
                    assert old.get(key)==obj.get(key),(ident,key)
            else:
                assert part['end']-part['start']==old['triangles']*3,(ident,'faces')
                assert part['lineEnd']-part['lineStart']==old['lineSegments']*2,(ident,'lines')
            if len(seen)%stride or not old.get('available'):continue
            if actual_raw is None:actual_raw,actual_header=block(args.android/obj['url'])
            original,header=block(args.reference/old['url'])
            if part is None:
                assert original==actual_raw,(ident,'unbatched bytes')
            else:
                v,n,l,c=header[2:6];av,an,al,ac=actual_header[2:6]
                assert c==ac
                first=part['start'];line_first=part['lineStart']
                def pos(buf,offset,index):return struct.unpack_from('<3f',buf,offset+index*12)
                for i in range(n):
                    oi=struct.unpack_from('<I',original,32+v*24+i*4)[0]
                    ai=struct.unpack_from('<I',actual_raw,32+av*24+(first+i)*4)[0]
                    op=pos(original,32,oi);ap=pos(actual_raw,32,ai)
                    for axis in range(3):
                        x=op[axis]+old['origin'][axis];y=ap[axis]+obj['origin'][axis]
                        assert abs(x-y)<=max(1.1e-4,abs(op[axis])*1.1e-6),(ident,'vertex',x,y)
                    assert pos(original,32+v*12,oi)==pos(actual_raw,32+av*12,ai),(ident,'normal')
                    if c:
                        assert pos(original,32+v*24+n*4+l*12,oi)==pos(actual_raw,32+av*24+an*4+al*12,ai),(ident,'color')
                for i in range(l):
                    op=pos(original,32+v*24+n*4,i);ap=pos(actual_raw,32+av*24+an*4,line_first+i)
                    for axis in range(3):
                        x=op[axis]+old['origin'][axis];y=ap[axis]+obj['origin'][axis]
                        assert abs(x-y)<=max(1.1e-4,abs(op[axis])*1.1e-6),(ident,'line',x,y)
            sampled+=1
    assert seen==set(expected),(len(seen),len(expected))
    print(f'PASS: {len(seen)} source objects, styles and primitive counts; {sampled} sampled geometries match')


if __name__=='__main__':main()
