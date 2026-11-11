#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Verify CAD text vectors, annotations and original drawing geometry together."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time
import numpy as np
import test_cad_stream as cad

ROOT=cad.ROOT
BASE=ROOT/'build/ios/cad-text-tests'
SOURCES=BASE/'sources'
EXE=ROOT/'build/ios/cad-text-stream'


def text(value='AB',point=(0,0,0),height=1,rotation=0,width=1,oblique=0,flags=0,h=0,v=0,align=None,normal=(0,0,1),handle='500'):
    data=[(0,'TEXT'),(5,handle),(8,'0'),(1,value),(10,point[0]),(20,point[1]),(30,point[2]),(40,height),(50,rotation),(41,width),(51,oblique),(71,flags),(72,h),(73,v),(210,normal[0]),(220,normal[1]),(230,normal[2])]
    if align:data += [(11,align[0]),(21,align[1]),(31,align[2])]
    return data


def prepare():
    SOURCES.mkdir(parents=True,exist_ok=True)
    for name,entities in {
        'plain':text(),
        'transformed':text(point=(10,20,30),height=2,rotation=90,width=1.5,oblique=15),
        'mirrored':text(flags=6),
        'top-center':text(h=1,v=3,align=(10,20,0)),
        'fit':text(h=5,align=(10,0,0)),
        'aligned':text(h=3,align=(10,0,0)),
        'ocs':text(point=(10,20,30),normal=(0,1,0)),
        'chinese-hole':text('口'),
        'latin-hole':text('O'),
        'symbols':text('%%c20 %%p0.5 %%d90'),
        'underline-range':text('A%%uB%%uC'),
        'chinese-overlap':text('中文标注'),
        'attribute-reference':text('构件A-123',point=(10,20,0),height=2,rotation=90),
        'mtext-narrow':[(0,'MTEXT'),(5,'500'),(8,'0'),(10,0),(20,0),(30,0),(40,1),(41,0),(71,1),(1,'AB')],
        'mtext-wide':[(0,'MTEXT'),(5,'500'),(8,'0'),(10,0),(20,0),(30,0),(40,1),(41,0),(71,1),(1,r'{\W2;AB}')],
        'wrap-narrow':[(0,'MTEXT'),(5,'500'),(8,'0'),(10,0),(20,0),(30,0),(40,1),(41,5),(71,1),(1,'AB AB')],
        'wrap-wide':[(0,'MTEXT'),(5,'500'),(8,'0'),(10,0),(20,0),(30,0),(40,1),(41,5),(71,1),(1,r'{\W2;AB AB}')],
        'mtext':[(0,'MTEXT'),(5,'500'),(8,'0'),(10,10),(20,20),(30,0),(40,1),(41,8),(71,1),(1,r'{\C1;中文}\P{\H2x;B}\P\L下划线\l')],
        'wrapped':[(0,'MTEXT'),(5,'500'),(8,'0'),(10,0),(20,0),(30,0),(40,1),(41,3),(71,1),(1,'ABCDE FGHIJ KLMNO')],
        'unsupported':cad.line('500',(0,0,0),(1,0,0))+[(0,'O3DV_UNKNOWN'),(5,'501'),(8,'0')],
    }.items():cad.drawing(SOURCES/(name+'.dxf'),entities)
    # Attribute values already have their position in the containing drawing;
    # applying the owning INSERT's scale/rotation again would displace them.
    definition=[(0,'ATTDEF'),(5,'300'),(8,'0'),(2,'CODE'),(1,'默认'),(3,'编号'),(10,0),(20,0),(30,0),(40,1),(70,0)]
    constant=[(0,'ATTDEF'),(5,'301'),(8,'0'),(2,'CONST'),(1,'常量'),(10,0),(20,2),(30,0),(40,1),(70,2)]
    attribute=[(0,'ATTRIB'),(5,'501'),(8,'0'),(2,'CODE'),(1,'构件A-123'),(10,10),(20,20),(30,0),(40,2),(50,90),(70,0)]
    hidden=[(0,'ATTRIB'),(5,'502'),(8,'0'),(2,'HIDE'),(1,'隐藏属性'),(10,40),(20,20),(30,0),(40,1),(70,1)]
    cad.drawing(SOURCES/'attributes.dxf',cad.insert('500','BLOCK',(10,20,0),(2,2,2),90,extra=[(66,1)])+attribute+hidden+[(0,'SEQEND'),(5,'503')],[('30','BLOCK',(0,0,0),definition+constant)])
    saved=cad.line('300',(0,2,0),(10,2,0))+text('10.00',point=(5,2.5,0),height=.5,handle='301')
    dimension=[(0,'DIMENSION'),(5,'500'),(8,'0'),(2,'*D1'),(10,0),(20,2),(30,0),(11,5),(21,2.5),(31,0),(70,0),(13,0),(23,0),(33,0),(14,10),(24,0),(34,0),(50,0)]
    cad.drawing(SOURCES/'saved-dimension.dxf',dimension,[('30','*D1',(0,0,0),saved)])
    for mode in ['normal','suppressed']:
        subprocess.run([str(cad.RUST/'cad-fixtures'),'dimension',str(SOURCES/('generated-'+mode+'.dxf')),mode],check=True)
    for version in ['AC1015','AC1018','AC1021','AC1024','AC1027','AC1032']:
        subprocess.run([str(cad.RUST/'cad-fixtures'),str(SOURCES/'mtext.dxf'),str(SOURCES/(version+'.dwg')),version],check=True)


def run(source,name=None,expected=0,environment=None):
    cache=BASE/'caches'/(name or source.stem);started=time.monotonic()
    result=subprocess.run([str(EXE),str(source),str(cache)],capture_output=True,text=True,env={**os.environ,**(environment or {})},timeout=180)
    assert result.returncode==expected,(source,result.stdout[-500:],result.stderr[-1500:])
    if expected:
        assert not cache.exists();return {'name':name or source.stem,'error':result.stderr.strip()}
    m=json.loads((cache/'manifest.json').read_text());assert m['reader']=='cad-stream-4' and m['complete'];assert m['objectCount']==len(m['objects'])
    return m,cad.geometry(cache,m),round(time.monotonic()-started,3)


def inside(points,p):
    a,b,c=points[:,0,:2],points[:,1,:2],points[:,2,:2]
    cross=lambda x,y:x[:,0]*y[:,1]-x[:,1]*y[:,0]
    signs=np.array([cross(b-a,p-a),cross(c-b,p-b),cross(a-c,p-c)])
    return ((signs>=-1e-10).all(axis=0)|(signs<=1e-10).all(axis=0)).any()


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--work-files',action='store_true');args=parser.parse_args();prepare();rows=[]
    plain,(_,triangles),_=run(SOURCES/'plain.dxf');reference=triangles.copy();assert len(triangles)>10 and plain['textObjects']==1
    for name in ['transformed','mirrored','ocs','top-center','fit','aligned']:
        m,(_,actual),_=run(SOURCES/(name+'.dxf'));expected=reference.copy()
        if name=='transformed':
            expected[:,:,0]=reference[:,:,0]*3+reference[:,:,1]*2*np.tan(np.pi/12);expected[:,:,1]=reference[:,:,1]*2
            expected=expected@np.array([[0,1,0],[-1,0,0],[0,0,1]])+[10,20,30]
        elif name=='mirrored':expected[:,:,:2]*=-1
        elif name=='ocs':expected=np.stack((-expected[:,:,0]-10,np.full(expected.shape[:2],30),expected[:,:,1]+20),axis=2)
        elif name=='top-center':expected+=np.array([10-plain['annotations'][0]['layout'][0]/2,20-plain['annotations'][0]['layout'][4],0])
        else:
            factor=10/plain['annotations'][0]['layout'][0];expected[:,:,0]*=factor
            if name=='aligned':expected[:,:,1]*=factor
        assert expected.shape==actual.shape and np.max(np.abs(actual-expected))<2e-5,(name,actual[:2],expected[:2])
    for name in ['chinese-hole','latin-hole']:
        m,(_,triangles),_=run(SOURCES/(name+'.dxf'));p=triangles.reshape(-1,3);center=(p[:,:2].min(axis=0)+p[:,:2].max(axis=0))/2
        assert len(triangles)>8 and not inside(triangles,center),(name,'glyph hole filled')
        area=np.linalg.norm(np.cross(triangles[:,1]-triangles[:,0],triangles[:,2]-triangles[:,0]),axis=1).sum()/2
        assert 0<area<np.prod(p[:,:2].max(axis=0)-p[:,:2].min(axis=0))*.9
    narrow,(_,narrow_tri),_=run(SOURCES/'mtext-narrow.dxf')
    wide,(_,wide_tri),_=run(SOURCES/'mtext-wide.dxf')
    expected_bounds=np.array(narrow['bounds']);expected_bounds[[0,3]]*=2
    assert np.max(np.abs(expected_bounds-wide['bounds']))<2e-5
    area=lambda tri:np.linalg.norm(np.cross(tri[:,1]-tri[:,0],tri[:,2]-tri[:,0]),axis=1).sum()/2
    assert abs(area(wide_tri)/(area(narrow_tri)*2)-1)<.002
    assert abs(wide['annotations'][0]['layout'][0]-narrow['annotations'][0]['layout'][0]*2)<1e-6
    wrap_narrow,_,_=run(SOURCES/'wrap-narrow.dxf');wrap_wide,_,_=run(SOURCES/'wrap-wide.dxf')
    assert wrap_wide['bounds'][4]-wrap_wide['bounds'][1]>wrap_narrow['bounds'][4]-wrap_narrow['bounds'][1]+1
    underline,(segments,_),_=run(SOURCES/'underline-range.dxf')
    assert underline['annotations'][0]['value']=='ABC' and len(segments)==1 and segments[0,0,0]>0 and segments[0,1,0]<underline['bounds'][3]
    overlap,(_,overlap_tri),_=run(SOURCES/'chinese-overlap.dxf');assert len(overlap_tri)>20
    for name in ['symbols','mtext','wrapped','attributes','saved-dimension','generated-normal','generated-suppressed']:
        m,(_,triangles),seconds=run(SOURCES/(name+'.dxf'));values=[a['value'] for a in m['annotations']]
        if name=='symbols':assert values==['Ø20 ±0.5 °90']
        if name=='mtext':assert values==['中文\nB\n下划线'] and m['lineSegments']>0 and any(o['color']==[1,0,0]for o in m['objects'])
        if name=='wrapped':assert m['bounds'][4]-m['bounds'][1]>2
        if name=='attributes':
            assert '构件A-123'in values and '常量'in values and '默认'not in values;assert any(not o['visible']for o in m['objects'])
            _,(_,reference_tri),_=run(SOURCES/'attribute-reference.dxf')
            actual=[]
            for entry in m['objects']:
                _,chunk_tri=cad.geometry(BASE/'caches/attributes',{'objects':[entry]})
                for part in entry['parts']:
                    if part['name']=='ATTRIB · 构件A-123':actual.append(chunk_tri[part['start']//3:part['end']//3])
            actual=np.concatenate(actual)
            assert actual.shape==reference_tri.shape and np.max(np.abs(actual-reference_tri))<2e-5,'INSERT attribute transformed twice'
        if name=='saved-dimension':assert values==['10.00'] and m['dimensionObjects']==1 and m['lineSegments']==1
        if name=='generated-normal':assert values==['100.00 mm'] and m['dimensionObjects']==1 and m['lineSegments']>=3
        if name=='generated-suppressed':assert not values and m['lineSegments']>=3
        rows.append({'name':name,'textObjects':m['textObjects'],'dimensionObjects':m['dimensionObjects'],'triangles':m['triangles'],'lineSegments':m['lineSegments'],'seconds':seconds,'values':values})
    for version in ['AC1015','AC1018','AC1021','AC1024','AC1027','AC1032']:
        m,_,_=run(SOURCES/(version+'.dwg'));assert m['annotations'][0]['value']=='中文\nB\n下划线'
    for name,settings in [('cancel',{'O3DV_TEST_CANCEL':'1'}),('cancel-ready',{'O3DV_TEST_CANCEL_AFTER_READY':'1'}),('budget',{'O3DV_TEST_DECODER_BUDGET':'1'})]:rows.append(run(SOURCES/'mtext.dxf',name,1,settings))
    if args.work_files:
        original=json.loads((ROOT/'build/ios/cad-stream-tests/native-results.json').read_text())
        for index,row in enumerate(r for r in original if r.get('path')):
            source=Path(row['path']);before=source.stat();m,_,seconds=run(source,'work-'+str(index+1));after=source.stat();assert(before.st_size,before.st_mtime_ns)==(after.st_size,after.st_mtime_ns)
            assert not any(o['type']in{'TEXT','MTEXT','ATTRIB','ATTDEF'}for o in m['unsupported'])
            rows.append({'name':source.name,'path':str(source),'cache':'work-'+str(index+1),'triangles':m['triangles'],'lineSegments':m['lineSegments'],'textObjects':m['textObjects'],'dimensionObjects':m['dimensionObjects'],'seconds':seconds,'warnings':m['warnings']})
            print('PASS work',source.name,m['textObjects'],m['dimensionObjects'],m['triangles'],flush=True)
    (BASE/'native-results.json').write_text(json.dumps(rows,ensure_ascii=False,indent=2)+'\n');print('PASS CAD text: glyph holes, transforms, alignment, CJK, formatted paragraphs, attributes and dimensions',flush=True)


if __name__=='__main__':main()
