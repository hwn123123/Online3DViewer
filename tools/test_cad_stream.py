#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Check authored CAD geometry, block transforms, complete caches and failures."""
import argparse
import json
import os
import shutil
from pathlib import Path
import struct
import subprocess
import time
import numpy as np

ROOT=Path(__file__).resolve().parent.parent
BASE=ROOT/'build/ios/cad-stream-tests'
RUST=ROOT/'build/ios/cad-target/release'


def drawing(path,entities,blocks=(),layers=()):
    pairs=[(0,'SECTION'),(2,'HEADER'),(9,'$ACADVER'),(1,'AC1021'),(9,'$INSUNITS'),(70,6),(0,'ENDSEC'),
           (0,'SECTION'),(2,'TABLES'),(0,'TABLE'),(2,'LAYER'),(70,len(layers)+1),
           (0,'LAYER'),(5,'20'),(2,'0'),(70,0),(62,7),(6,'CONTINUOUS')]
    for i,(name,color) in enumerate(layers):pairs += [(0,'LAYER'),(5,hex(33+i)[2:]),(2,name),(70,0),(62,color),(6,'CONTINUOUS')]
    pairs += [(0,'ENDTAB'),(0,'TABLE'),(2,'BLOCK_RECORD'),(70,len(blocks)+2)]
    for handle,name in [('10','*Model_Space'),('11','*Paper_Space')]+[(block[0],block[1]) for block in blocks]:
        pairs += [(0,'BLOCK_RECORD'),(5,handle),(2,name),(70,0)]
    pairs += [(0,'ENDTAB'),(0,'ENDSEC'),(0,'SECTION'),(2,'BLOCKS')]
    for handle,name,base,content in blocks:
        pairs += [(0,'BLOCK'),(5,hex(int(handle,16)+0x100)[2:]),(330,handle),(8,'0'),(2,name),(70,0),(10,base[0]),(20,base[1]),(30,base[2]),(3,name)]
        pairs += content
        pairs += [(0,'ENDBLK'),(330,handle),(8,'0')]
    pairs += [(0,'ENDSEC'),(0,'SECTION'),(2,'ENTITIES')]+entities+[(0,'ENDSEC'),(0,'EOF')]
    path.write_text(''.join(f'{code}\n{value}\n' for code,value in pairs))


def line(handle,a,b,layer='0',extra=()):
    return [(0,'LINE'),(5,handle),(8,layer),(10,a[0]),(20,a[1]),(30,a[2]),(11,b[0]),(21,b[1]),(31,b[2]),*extra]


def insert(handle,name,point,scale=(1,1,1),rotation=0,layer='0',extra=()):
    return [(0,'INSERT'),(5,handle),(8,layer),(2,name),(10,point[0]),(20,point[1]),(30,point[2]),(41,scale[0]),(42,scale[1]),(43,scale[2]),(50,rotation),*extra]


def prepare():
    sources=BASE/'sources';sources.mkdir(parents=True,exist_ok=True)
    drawing(sources/'line.dxf',line('500',(1e9+.125,-2.5,7),(1e9+2.125,4.5,-9),'构件'),layers=[('构件',1)])
    block=[('30','梁',(1,2,3),line('300',(1,2,3),(2,2,3),extra=[(62,0)])),
           ('40','组合',(0,0,0),insert('400','梁',(10,0,0),(2,3,4),90))]
    drawing(sources/'instances.dxf',insert('500','组合',(100,200,300),(2,1,1),0,'构件'),block,layers=[('构件',1)])
    drawing(sources/'ocs-array.dxf',insert('500','梁',(10,20,30),(2,3,4),90,'构件',[(210,0),(220,1),(230,0),(70,2),(71,2),(44,5),(45,7)]),block[:1],layers=[('构件',3)])
    drawing(sources/'curves.dxf',[(0,'CIRCLE'),(5,'500'),(8,'0'),(10,0),(20,0),(30,0),(40,10),(210,0),(220,1),(230,0),
            (0,'LWPOLYLINE'),(5,'501'),(8,'0'),(90,2),(70,0),(10,0),(20,0),(42,1),(10,20),(20,0),(42,0)])
    drawing(sources/'visibility.dxf',line('500',(0,0,0),(1,0,0),'隐藏')+insert('501','梁',(0,0,0),layer='隐藏')+line('502',(0,1,0),(1,1,0),extra=[(60,1)]),block[:1],layers=[('隐藏',-3)])
    drawing(sources/'unsupported.dxf',line('500',(0,0,0),(1,0,0))+[(0,'O3DV_UNKNOWN'),(5,'501'),(8,'0')])
    drawing(sources/'missing-block.dxf',insert('500','不存在',(0,0,0)))
    drawing(sources/'cycle.dxf',insert('500','循环',(0,0,0)),[('30','循环',(0,0,0),insert('300','循环',(0,0,0)))])
    (sources/'bad-header.dwg').write_bytes(b'not-a-drawing')
    subprocess.run([str(RUST/'cad-fixtures'),'mesh',str(sources/'concave.dxf'),'unused'],check=True)
    for mode in ['repeat','collinear','clockwise','degenerate']:
        subprocess.run([str(RUST/'cad-fixtures'),'mesh-'+mode,str(sources/('mesh-'+mode+'.dxf')),'unused'],check=True)
    for version in ['AC1015','AC1018','AC1021','AC1024','AC1027','AC1032']:
        subprocess.run([str(RUST/'cad-fixtures'),str(sources/'instances.dxf'),str(sources/(version+'.dwg')),version],check=True)
    data=(sources/'AC1032.dwg').read_bytes();(sources/'truncated.dwg').write_bytes(data[:len(data)//2])
    return sources


def geometry(cache,manifest):
    lines=[];triangles=[]
    for entry in manifest['objects']:
        data=(cache/entry['url']).read_bytes();assert len(data)==entry['bytes']
        magic,version,vertices,indices,line_vertices,colors,uvs,tangents=struct.unpack_from('<8I',data)
        assert magic==0x3144334f and version==3 and not(colors or uvs or tangents)
        origin=np.array(entry['origin']);positions=np.frombuffer(data,'<f4',vertices*3,32).reshape(-1,3)+origin
        index=np.frombuffer(data,'<u4',indices,32+vertices*24)
        assert (index<vertices).all()
        if indices:triangles.append(positions[index].reshape(-1,3,3))
        if line_vertices:lines.append(np.frombuffer(data,'<f4',line_vertices*3,32+vertices*24+indices*4).reshape(-1,2,3)+origin)
    return (np.concatenate(lines) if lines else np.empty((0,2,3)),np.concatenate(triangles) if triangles else np.empty((0,3,3)))


def run(executable,source,name=None,environment=None,expected=0):
    cache=BASE/'fixture-caches'/(name or source.stem);start=time.monotonic()
    result=subprocess.run([str(executable),str(source),str(cache)],env={**os.environ,**(environment or {})},capture_output=True,text=True,timeout=180)
    assert result.returncode==expected,(source,result.stdout[-500:],result.stderr[-1200:])
    if expected:
        assert not cache.exists(),('unfinished cache retained',cache)
        return {'name':name or source.name,'error':result.stderr.strip()}
    manifest=json.loads((cache/'manifest.json').read_text());assert manifest['complete'] and manifest['reader']=='cad-stream-4'
    assert manifest['objectCount']==len(manifest['objects'])
    return manifest,geometry(cache,manifest),round(time.monotonic()-start,3)


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--executable',type=Path,default=RUST/'cad-stream');parser.add_argument('--work-files',action='store_true');args=parser.parse_args()
    sources=prepare();results=[]
    m,(lines,triangles),seconds=run(args.executable,sources/'line.dxf')
    assert len(lines)==1 and not len(triangles)
    assert np.max(np.abs(lines[0]-[[1e9+.125,-2.5,7],[1e9+2.125,4.5,-9]]))<1e-6
    for name in ['instances.dxf',*[version+'.dwg' for version in ['AC1015','AC1018','AC1021','AC1024','AC1027','AC1032']]]:
        m,(lines,_),seconds=run(args.executable,sources/name)
        assert len(lines)==1 and np.max(np.abs(lines[0]-[[120,200,300],[120,202,300]]))<1e-5,(name,lines)
        layer=next(layer for layer in m['layers'] if layer['name']=='构件')
        assert m['objects'][0]['layerIndex']==layer['index']
        assert m['objects'][0]['color']==[1,0,0]
        results.append({'name':name,'seconds':seconds,'lineSegments':len(lines)})
    renamed=sources/'任意文件名.DWG';shutil.copyfile(sources/'AC1032.dwg',renamed)
    renamed_manifest,_,_=run(args.executable,renamed,name='renamed')
    original_manifest=json.loads((BASE/'fixture-caches/AC1032/manifest.json').read_text())
    assert renamed_manifest['objects']==original_manifest['objects']
    for entry in renamed_manifest['objects']:
        assert (BASE/'fixture-caches/renamed'/entry['url']).read_bytes()==(BASE/'fixture-caches/AC1032'/entry['url']).read_bytes()
    results.append({'name':'rename-independent','geometryBytesIdentical':True})
    m,(lines,_),_=run(args.executable,sources/'ocs-array.dxf')
    expected=[]
    for row in range(2):
        for col in range(2):
            # OCS normal +Y: X=-world X, Y=world Z, Z=world Y.
            # Rotation 90deg: array x offset becomes OCS y, y becomes -x.
            a=np.array([-10+row*7,30,20+col*5]);expected.append([a,a+[0,0,2]])
    assert np.max(np.abs(lines-np.array(expected)))<1e-5,(lines,expected)
    m,(lines,_),_=run(args.executable,sources/'curves.dxf')
    assert np.max(np.abs(m['bounds']-np.array([-10,-10,-10,20,0,10])))<.002
    assert abs(np.linalg.norm(lines[:,1]-lines[:,0],axis=1).sum()-30*np.pi)<.02
    m,(_,triangles),_=run(args.executable,sources/'concave.dxf')
    assert len(triangles)==3
    area=np.linalg.norm(np.cross(triangles[:,1]-triangles[:,0],triangles[:,2]-triangles[:,0]),axis=1).sum()/2
    assert abs(area-3)<1e-6
    for mode in ['repeat','collinear','clockwise','degenerate']:
        m,(_,triangles),_=run(args.executable,sources/('mesh-'+mode+'.dxf'))
        vectors=np.cross(triangles[:,1]-triangles[:,0],triangles[:,2]-triangles[:,0])
        area=np.linalg.norm(vectors,axis=1).sum()/2
        assert abs(area-(0 if mode=='degenerate' else 3))<1e-6,(mode,area)
        if mode=='clockwise':assert (vectors[:,2]<0).all()
        elif mode!='degenerate':assert (vectors[:,2]>0).all()
    m,_,_=run(args.executable,sources/'visibility.dxf')
    hidden=next(layer['index'] for layer in m['layers'] if layer['name']=='隐藏')
    assert any(hidden in entry['visibilityLayers'] and entry['visible'] for entry in m['objects'])
    assert any(not entry['visible'] for entry in m['objects'])
    m,_,_=run(args.executable,sources/'unsupported.dxf')
    assert m['warnings'] and not m['coverageComplete'] and any(item['type']=='UNKNOWN' for item in m['unsupported'])
    for name in ['missing-block.dxf','cycle.dxf','bad-header.dwg','truncated.dwg']:
        results.append(run(args.executable,sources/name,expected=1))
    for label,env in [('cancel',{'O3DV_TEST_CANCEL':'1'}),('budget',{'O3DV_TEST_DECODER_BUDGET':'1'})]:
        results.append(run(args.executable,sources/'instances.dxf',name=label,environment=env,expected=1))
    if args.work_files:
        inventory=json.loads((ROOT/'build/ios/work-model-tests/inventory.json').read_text());group={}
        for item in inventory:
            if item['format']=='dwg':
                with open(item['path'],'rb') as f:version=f.read(6).decode('ascii')
                group.setdefault(version,[]).append(item)
        for version,rows in sorted(group.items()):
            row=min(rows,key=lambda r:r['bytes']);source=Path(row['path']);before=source.stat();m,_,seconds=run(args.executable,source,name='work-'+version);after=source.stat()
            assert (before.st_size,before.st_mtime_ns)==(after.st_size,after.st_mtime_ns)
            results.append({'name':source.name,'path':str(source),'version':version,'seconds':seconds,'triangles':m['triangles'],'lineSegments':m['lineSegments'],'coverageComplete':m['coverageComplete'],'warnings':m['warnings']})
            print('PASS work',version,source.name,m['triangles'],m['lineSegments'],flush=True)
        audit=json.loads((ROOT/'build/ios/dwg-dxf-tests/all-strict.json').read_text())
        for feature in ['MESH','3DFACE']:
            rows=[r for r in audit['results'] if not r['decoder']['error'] and any(s['inventory']['modelEntityTypes'].get(feature) for s in r['decoder']['shards'])]
            row=min(rows,key=lambda r:r['bytes']);source=Path(row['path']);before=source.stat()
            m,_,seconds=run(args.executable,source,name='work-'+feature)
            assert m['triangles']>0
            after=source.stat();assert (before.st_size,before.st_mtime_ns)==(after.st_size,after.st_mtime_ns)
            results.append({'name':source.name,'path':str(source),'feature':feature,'seconds':seconds,'triangles':m['triangles'],'lineSegments':m['lineSegments'],'coverageComplete':m['coverageComplete'],'warnings':m['warnings']})
            print('PASS work',feature,source.name,m['triangles'],m['lineSegments'],flush=True)
        largest=max((r for r in inventory if r['format']=='dwg'),key=lambda r:r['bytes'])
        original=Path(largest['path']);before=original.stat()
        stopped=run(args.executable,original,name='largest-resource-rejection',expected=1)
        assert 'O3DVCAD:2' in stopped['error'],stopped
        after=original.stat();assert (before.st_size,before.st_mtime_ns)==(after.st_size,after.st_mtime_ns)
        results.append(stopped)
        cancel_source=Path(next(r['path'] for r in results if r.get('feature')=='MESH'))
        stopped=run(args.executable,cancel_source,name='late-cancel',environment={'O3DV_TEST_CANCEL_AFTER_READY':'1'},expected=1)
        assert 'O3DVCAD:3' in stopped['error'],stopped
        results.append(stopped)
    (BASE/'native-results.json').write_text(json.dumps(results,ensure_ascii=False,indent=2))
    print('PASS CAD: geometry, six DWG versions, blocks, OCS arrays, concave faces, visibility, warnings and failure cleanup',flush=True)


if __name__=='__main__':main()
