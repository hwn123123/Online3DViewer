#!/usr/bin/env python3
"""Compare native Draco caches to unmodified-WASM-decoded glTF references."""
import array
import copy
import json
import math
import os
from pathlib import Path
import shutil
import struct
import subprocess
import time

import test_gltf_stream as gltf

ROOT=Path(__file__).resolve().parent.parent
OUT=ROOT/'build/ios/draco-stream-tests'
CLI=ROOT/'build/ios/gltf-stream'


def convert(source,directory,env=None,expected=0):
    if directory.exists():shutil.rmtree(directory)
    run=subprocess.run([str(CLI),str(source),str(directory)],capture_output=True,text=True,timeout=180,env={**os.environ,**(env or {})})
    assert run.returncode==expected,(source,run.returncode,run.stderr)
    return run


def compare(a,b):
    da,db=[json.loads((p/'manifest.json').read_text()) for p in [a,b]]
    for key in ['objectCount','sourceObjectCount','triangles','vertices','lineSegments','points']:
        assert da[key]==db[key],(key,da[key],db[key])
    max_error=0;different=0
    for x,y in zip(da['objects'],db['objects']):
        for key in ['sourceNode','sourceMesh','primitiveIndex','drawMode','vertices','triangles','lineSegments','materialIndex']:
            assert x[key]==y[key],(key,x[key],y[key])
        for key in ['bounds','geometryBounds','origin','transform']:
            assert all(math.isclose(p,q,rel_tol=2e-6,abs_tol=2e-5) for p,q in zip(x[key],y[key])),(key,x[key],y[key])
        raw_a,raw_b=(a/x['url']).read_bytes(),(b/y['url']).read_bytes()
        assert raw_a[:32]==raw_b[:32]
        _,version,n,indices,lines,colors,uv,flags=struct.unpack_from('<8I',raw_a)
        start=32+n*24;assert raw_a[start:start+indices*4]==raw_b[start:start+indices*4]
        if raw_a!=raw_b:
            different+=1;va=array.array('f');vb=array.array('f');va.frombytes(raw_a[32:start]+raw_a[start+indices*4:]);vb.frombytes(raw_b[32:start]+raw_b[start+indices*4:])
            for p,q in zip(va,vb):
                assert math.isfinite(p) and math.isfinite(q) and math.isclose(p,q,rel_tol=2e-5,abs_tol=2e-5),(p,q)
                max_error=max(max_error,abs(p-q))
    return {'maxAttributeError':max_error,'nonidenticalBlocksWithinTolerance':different,'manifest':da}


def main():
    records=[]
    for row in json.loads((OUT/'fixtures.json').read_text()):
        records.append({'name':row['name'],'source':OUT/'sources'/row['source'],'reference':OUT/'sources'/row['reference']})
    for row in json.loads((OUT/'official-references.json').read_text()):
        records.append({'name':Path(row['source']).stem,'source':ROOT/row['source'],'reference':ROOT/row['reference']})
    results=[]
    for row in records:
        name=row['name'];a=OUT/'caches'/name;b=OUT/'references'/name
        started=time.monotonic();run=convert(row['source'],a);convert(row['reference'],b)
        result=compare(a,b);d=result.pop('manifest')
        assert d['complete'] and d['dracoDecodedPrimitiveCount']>0
        assert d['dracoPeakAllocationBytes']<=d['dracoDecoderBudgetBytes']
        assert not list(a.glob('.parse-memory-*'))
        events=[json.loads(line) for line in run.stdout.splitlines()]
        assert events[0]['phase']=='decoding' and events[-1]['phase']=='complete'
        r={**row,'source':str(row['source'].relative_to(ROOT)),'reference':str(row['reference'].relative_to(ROOT)),
           'cache':str(a.relative_to(ROOT)),'referenceCache':str(b.relative_to(ROOT)),**result,'sourceBytes':row['source'].stat().st_size,
           'triangles':d['triangles'],'blocks':d['objectCount'],'decodedPrimitives':d['dracoDecodedPrimitiveCount'],
           'footprintBytes':d['nativePeakFootprintBytes'],'decoderPeakLogicalBytes':d['dracoPeakAllocationBytes'],'workspaceDiskBytes':d['dracoWorkspaceDiskBytes'],
           'seconds':round(time.monotonic()-started,3)}
        results.append(r);print('PASS',name,d['triangles'],'faces',result,flush=True)
    # Metadata / bitstream errors must never produce a complete cache.
    source=OUT/'sources/edgebreaker.glb';doc,buffers=gltf.load(source);negatives=[]
    variants={}
    bad=copy.deepcopy(doc);bad['meshes'][0]['primitives'][0]['extensions']['KHR_draco_mesh_compression']['attributes']['POSITION']=4294967295;variants['missing-attribute-id']=(bad,buffers[0])
    bad=copy.deepcopy(doc);bad['meshes'][0]['primitives'][0]['extensions']['KHR_draco_mesh_compression']['attributes']['POSITION']=-1;variants['negative-attribute-id']=(bad,buffers[0])
    bad=copy.deepcopy(doc);bad['accessors'][bad['meshes'][0]['primitives'][0]['attributes']['POSITION']]['count']+=1;variants['mismatched-count']=(bad,buffers[0])
    bad=copy.deepcopy(doc);bad['meshes'][0]['primitives'][0]['mode']=1;variants['wrong-topology']=(bad,buffers[0])
    variants['invalid-header']=(copy.deepcopy(doc),b'NOPE'+buffers[0][4:])
    bad=copy.deepcopy(doc);data=buffers[0][:-20];bad['bufferViews'][0]['byteLength']=len(data);variants['truncated-stream']=(bad,data)
    for name,(d,data) in variants.items():
        path=OUT/'sources'/(name+'.glb');gltf.write_glb(path,d,data);directory=OUT/'negative'/name
        run=convert(path,directory,expected=1);assert 'O3DVGLTF:1' in run.stderr,(name,run.stderr)
        assert not (directory/'manifest.json').exists() or not json.loads((directory/'manifest.json').read_text())['complete']
        negatives.append({'name':name,'error':run.stderr.strip()})
    for key,code in [('CANCEL',3),('CANCEL_AFTER_READY',3),('CANCEL_DURING_DECODE',3),('CRITICAL_PRESSURE',2)]:
        run=convert(OUT/'sources/large.glb',OUT/'negative'/key,{'O3DV_TEST_'+key:'1'},1)
        assert f'O3DVGLTF:{code}' in run.stderr,(key,run.stderr)
        negatives.append({'name':key,'error':run.stderr.strip()})
    run=convert(source,OUT/'negative/decoder-budget',{'O3DV_TEST_DECODER_BUDGET':'512'},1)
    assert 'O3DVGLTF:2' in run.stderr and '预算' in run.stderr
    negatives.append({'name':'decoder-budget','error':run.stderr.strip()})
    (OUT/'native-results.json').write_text(json.dumps({'passed':True,'cases':results,'negative':negatives},ensure_ascii=False,indent=2)+'\n')
    print('PASS',len(results),'compressed/reference pairs and',len(negatives),'malformed/cancel/resource cases')


if __name__=='__main__':main()
