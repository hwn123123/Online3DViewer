#!/usr/bin/env python3
"""Independent checks for block placement; also prepare baked rendering controls."""
import argparse
import copy
import json
import math
import os
from pathlib import Path
import shutil
import struct
import subprocess

ROOT=Path(__file__).resolve().parent.parent
OUT=ROOT/'build/ios/rhino-geometry-tests'

def identity():return [[float(i==j) for j in range(4)] for i in range(4)]
def multiply(a,b):return [[sum(a[i][k]*b[k][j] for k in range(4)) for j in range(4)] for i in range(4)]
def transform(m,p):return tuple(sum(m[i][k]*p[k] for k in range(3))+m[i][3] for i in range(3))
def matrix(values):return [[values[j*4+i] for j in range(4)] for i in range(4)]
def inverse(a):
 rows=[list(row)+identity()[i] for i,row in enumerate(a)]
 for col in range(4):
  pivot=max(range(col,4),key=lambda r:abs(rows[r][col]));rows[col],rows[pivot]=rows[pivot],rows[col];n=rows[col][col];assert n
  rows[col]=[v/n for v in rows[col]]
  for row in range(4):
   if row!=col:
    scale=rows[row][col];rows[row]=[v-scale*w for v,w in zip(rows[row],rows[col])]
 return [r[4:] for r in rows]
def normal(m,n):
 inv=inverse(m);v=[sum(inv[c][r]*n[c] for c in range(3)) for r in range(3)];length=math.sqrt(sum(x*x for x in v));return tuple(x/length for x in v)
def determinant(m):return m[0][0]*(m[1][1]*m[2][2]-m[1][2]*m[2][1])-m[0][1]*(m[1][0]*m[2][2]-m[1][2]*m[2][0])+m[0][2]*(m[1][0]*m[2][1]-m[1][1]*m[2][0])
def decode(path):
 b=path.read_bytes();h=struct.unpack_from('<8I',b);_,v,n,ni,nl,col,uv,_=h;assert v==1 and not uv
 p=list(struct.iter_unpack('<3f',b[32:32+n*12]));norm=list(struct.iter_unpack('<3f',b[32+n*12:32+n*24]));idx=list(struct.unpack_from('<'+str(ni)+'I',b,32+n*24));start=32+n*24+ni*4
 lines=list(struct.iter_unpack('<3f',b[start:start+nl*12]));colors=b[start+nl*12:] if col else b''
 return h,p,norm,idx,lines,colors

def main():
 parser=argparse.ArgumentParser();parser.add_argument('--cli',type=Path,default=ROOT/'build/ios/rhino-stream');args=parser.parse_args()
 sources=OUT/'source-fixtures';cache=OUT/'affine'
 subprocess.run([str(args.cli),str(sources/'nested-affine.3dm'),str(cache)],check=True,capture_output=True)
 d=json.loads((cache/'manifest.json').read_text());assert d['complete'] and not d['unsupported'];assert d['sourceObjectCount']==9 and d['instanceReferenceCount']==7 and d['instanceLeafCount']==16
 assert len(list(cache.glob('*.bin')))==9 and d['geometryBytes']==sum(x.stat().st_size for x in cache.glob('*.bin'))
 roots={};red=identity();red[0][0]=1.2;red[1][1]=.8;red[2][2]=1.1;red[0][3]=-4;red[1][3]=-4;red[2][3]=1;roots['Root red']=red
 shear=identity();shear[0][1]=.3;shear[2][1]=.1;shear[0][3]=4;shear[1][3]=3;rotate=identity();c=math.cos(math.pi/6);s=math.sin(math.pi/6);rotate[1][1]=rotate[2][2]=c;rotate[1][2]=-s;rotate[2][1]=s;roots['Root blue shear']=multiply(shear,rotate)
 for name,(x,y) in [('Hidden object',(4,-4)),('Hidden parent layer',(-4,4))]:m=identity();m[0][3]=x;m[1][3]=y;roots[name]=m
 nested={};a=identity();a[0][3]=-1;a[1][3]=-2;a[2][3]=-3;nested['Nested identity']=a
 a=identity();a[0][0]=-1;a[1][1]=1.3;a[2][2]=.7;a[0][3]=3;a[1][3]=-2.6;a[2][3]=-2.1;nested['Nested mirror']=a
 clones=[o for o in d['objects'] if 'instanceId' in o];assert len({o['id'] for o in d['objects']})==len(d['objects']);assert len({o['url'] for o in clones})==2
 for o in clones:
  root,child,leaf=o['name'].split(' / ');expected=multiply(roots[root],nested[child]);actual=matrix(o['transform'])
  assert all(math.isclose(expected[i][j],actual[i][j],abs_tol=1e-10) for i in range(4) for j in range(4)),o['name']
  assert o['visible']==(root!='Hidden object')
  assert o['materialIndex']==(1 if root=='Root blue shear' else 0)
  expected_color=[20/255,40/255,220/255] if root=='Root blue shear' else [220/255,20/255,30/255]
  assert all(math.isclose(x,y,abs_tol=1e-7) for x,y in zip(o['color'],expected_color))
  line_color=[230/255,40/255,20/255] if leaf=='Diagonal curve' else [20/255,180/255,40/255]
  assert all(math.isclose(x,y,abs_tol=1e-7) for x,y in zip(o['lineColor'],line_color))
  assert math.isclose(o['opacity'],.65 if root=='Root blue shear' else 1,abs_tol=1e-7)
  assert len(o['instancePath'])==2 and not o['definitionMember']
  h,p,norm,idx,lines,_=decode(cache/o['url'])
  for v in p+lines:
   point=transform(actual,tuple(v[k]+o['origin'][k] for k in range(3)))
   assert all(o['bounds'][k]-1e-5<=point[k]<=o['bounds'][k+3]+1e-5 for k in range(3)),(o['name'],point,o['bounds'])
  if p:
   assert h[2]==4096 and len(idx)==23814
   assert all(abs(x-y)<1e-6 for x,y in zip(norm[0],(-.3/math.sqrt(1.13),-.2/math.sqrt(1.13),1/math.sqrt(1.13))))
 assert d['triangles']==8*7938 and d['lineSegments']==16
 print('PASS nested transforms, mirror, nonuniform scale, shear, material/color inheritance, visibility metadata and shared geometry')
 # Bake the same placed vertices independently to test the renderer's matrix and normals.
 fixtures=ROOT/'build/ios/memory-stream-tests/fixtures';actual_dir=fixtures/'rhino-instances';shutil.copytree(cache,actual_dir,dirs_exist_ok=True)
 baked=copy.deepcopy(d);baked['name']='Baked instance control';baked['objects']=[];baked_dir=fixtures/'rhino-instances-baked';baked_dir.mkdir(exist_ok=True)
 for i,o in enumerate(clones):
  item=copy.deepcopy(o);m=matrix(item.pop('transform'));h,p,norm,idx,lines,colors=decode(cache/o['url']);p=[transform(m,tuple(v[k]+o['origin'][k] for k in range(3))) for v in p];lines=[transform(m,tuple(v[k]+o['origin'][k] for k in range(3))) for v in lines];norm=[normal(m,v) for v in norm]
  if determinant(m)<0:
   for j in range(0,len(idx),3):idx[j+1],idx[j+2]=idx[j+2],idx[j+1]
  b=struct.pack('<8I',*h)+b''.join(struct.pack('<3f',*v) for v in p+norm)+struct.pack('<'+str(len(idx))+'I',*idx)+b''.join(struct.pack('<3f',*v) for v in lines)+colors
  item['origin']=[0,0,0];item['url']=f'baked-{i}.bin';item['bytes']=len(b);(baked_dir/item['url']).write_bytes(b);baked['objects'].append(item)
 baked['objectCount']=len(baked['objects']);(baked_dir/'manifest.json').write_text(json.dumps(baked))
 for variant,kind in [('rhino-instance-mesh','Mesh'),('rhino-instance-line','Curve')]:
  target=fixtures/variant;target.mkdir(exist_ok=True);item=next(o for o in clones if o['name'].startswith('Root red / Nested mirror') and o['type']==kind);v=copy.deepcopy(d);v.update(objects=[item],objectCount=1,sourceObjectCount=1,bounds=item['bounds'],triangles=item['triangles'],lineSegments=item['lineSegments']);shutil.copy2(cache/item['url'],target/item['url']);(target/'manifest.json').write_text(json.dumps(v))
 cases={'missing-definition':'missing_instance_definition','missing-member':'missing_definition_geometry','cycle':'recursive_instance_definition','unsupported-member':'unsupported_definition_geometry'}
 for name,reason in cases.items():
  output=OUT/name;result=subprocess.run([str(args.cli),str(sources/(name+'.3dm')),str(output)],capture_output=True,text=True);assert result.returncode==0,(name,result.stderr)
  state=json.loads((output/'manifest.json').read_text());assert state['complete'] and any(x.get('reason')==reason for x in state['unsupported']),(name,state['unsupported'])
  assert not any('instanceId' in o for o in state['objects']),name
  print('PASS explicit unsupported result:',name)
 result=subprocess.run([str(args.cli),str(sources/'nested-affine.3dm'),str(OUT/'cancelled')],env={**os.environ,'O3DV_TEST_CANCEL_ON_INSTANCE':'1'},capture_output=True,text=True)
 assert result.returncode==1 and '取消' in result.stderr;assert not json.loads((OUT/'cancelled/manifest.json').read_text())['complete'];print('PASS cancellation before instance resolution')
 (OUT/'instance-checks.json').write_text(json.dumps({'passed':True,'sourceObjects':d['sourceObjectCount'],'references':d['instanceReferenceCount'],'placedLeaves':d['instanceLeafCount'],'sharedGeometryFiles':2,'triangles':d['triangles'],'lineSegments':d['lineSegments']},indent=2))

if __name__=='__main__':main()
