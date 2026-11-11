#!/usr/bin/env python3
"""Generate format-independent paging fixtures; no user models are required."""
import struct,json
from pathlib import Path
out=Path('build/ios/memory-stream-tests/fixtures');out.mkdir(exist_ok=True)
for variant in ['opaque','transparent']:
 d=out/variant;d.mkdir(exist_ok=True);objects=[]
 for obj,(z,color) in enumerate([(0,[1,0,0]),(-.5,[0,0,1]),(.5,[0,1,0])]):
  n=64;p=[];normals=[];indices=[]
  for y in range(n):
   for x in range(n):p.extend([-1+2*x/(n-1),-1+2*y/(n-1),z]);normals.extend([0,0,1])
  for y in range(n-1):
   for x in range(n-1):a=y*n+x;indices.extend([a,a+1,a+n,a+1,a+n+1,a+n])
  data=struct.pack('<8I',0x3144334f,2,n*n,len(indices),0,0,0,0)+struct.pack(f'<{len(p)}f',*p)+struct.pack(f'<{len(normals)}f',*normals)+struct.pack(f'<{len(indices)}I',*indices)
  name=f'object-{obj}.bin';(d/name).write_bytes(data)
  objects.append(dict(id=f'plane-{obj}',index=obj,name=f'Plane {obj}',type='Mesh',layerIndex=0,materialIndex=-1,color=color,lineColor=[0,0,0],opacity=.5 if variant=='transparent' else 1,visible=True,definitionMember=False,available=True,bounds=[-1,-1,z,1,1,z],origin=[0,0,0],url=name,bytes=len(data),vertices=n*n,triangles=len(indices)//3,lineSegments=0))
 m=dict(format='o3dv-stream-1',name=variant,layers=[dict(id='root',index=0,name='Layer',visible=True)],materials=[],objects=objects,unsupported=[],complete=True,objectCount=3,sourceObjectCount=3,bounds=[-1,-1,-.5,1,1,.5],triangles=sum(x['triangles'] for x in objects),vertices=3*n*n,lineSegments=0,geometryBytes=sum(x['bytes'] for x in objects),nativePeakMemoryBytes=0)
 (d/'manifest.json').write_text(json.dumps(m))

# A v1 block verifies compatibility with the 3DM cache protocol.
import shutil
legacy=out/'legacy';shutil.copytree(out/'opaque',legacy,dirs_exist_ok=True)
m=json.loads((legacy/'manifest.json').read_text());m['name']='legacy'
for o in m['objects']:
 raw=bytearray((legacy/o['url']).read_bytes());struct.pack_into('<I',raw,4,1);(legacy/o['url']).write_bytes(raw)
(legacy/'manifest.json').write_text(json.dumps(m))
# A small, real PNG exercises the same bounded texture path as imported models.
tex=out/'texture';tex.mkdir(exist_ok=True)
shutil.copy2(Path('test/testfiles/obj/cube_texture.png'),tex/'texture.png')
p=[-1,-1,0,1,-1,0,1,1,0,-1,1,0];normals=[0,0,1]*4;indices=[0,1,2,0,2,3];uv=[0,0,1,0,1,1,0,1]
data=struct.pack('<8I',0x3144334f,2,4,6,0,0,1,0)+struct.pack('<12f',*p)+struct.pack('<12f',*normals)+struct.pack('<6I',*indices)+struct.pack('<8f',*uv)
(tex/'quad.bin').write_bytes(data)
o=dict(id='textured-plane',index=0,name='Textured plane',type='Mesh',layerIndex=0,materialIndex=0,color=[1,1,1],lineColor=[0,0,0],opacity=1,visible=True,definitionMember=False,available=True,bounds=[-1,-1,0,1,1,0],origin=[0,0,0],url='quad.bin',bytes=len(data),vertices=4,triangles=2,lineSegments=0)
m=json.loads((out/'opaque/manifest.json').read_text());m.update(name='TextureBudgetProbe',objects=[o],objectCount=1,sourceObjectCount=1,triangles=2,vertices=4,geometryBytes=len(data),bounds=o['bounds'],materials=[dict(index=0,name='Texture',color=[1,1,1],opacity=1,texture=dict(url='texture.png',matrix=[1,0,0,0,1,0,0,0,1],wrapU=True,wrapV=True))]);(tex/'manifest.json').write_text(json.dumps(m))

# A long missing-file status must not resize the native viewport after a completed frame.
warning=out/'missing-files';shutil.copytree(out/'opaque',warning,dirs_exist_ok=True)
m=json.loads((warning/'manifest.json').read_text());m['name']='LongStatusProbe';m['missingFiles']=[f'example-material-library-external-texture-with-a-long-file-name-{i}.png' for i in range(3)];(warning/'manifest.json').write_text(json.dumps(m))
