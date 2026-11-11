#!/usr/bin/env python3
"""Generate identical workload controls for cache sharing and read scheduling."""
import copy,json,shutil
from pathlib import Path
root=Path(__file__).resolve().parent.parent
base=root/'build/ios/memory-stream-tests/fixtures/opaque'
manifest=json.loads((base/'manifest.json').read_text());source=manifest['objects'][0]
for name,count,shared,version in [('many-instances',120,True,2),('distinct-blocks',48,False,2),('legacy-blocks',24,False,1)]:
 out=root/'build/ios/memory-stream-tests/fixtures'/name;out.mkdir(exist_ok=True);m=copy.deepcopy(manifest);objects=[];columns=12 if count==120 else 8
 for i in range(count):
  x=(i%columns-(columns-1)/2)*2.5;y=(i//columns-(count//columns-1)/2)*2.5
  o=copy.deepcopy(source);o.update(id=f'placement-{i}',index=i,name=f'Placement {i}',bounds=[x-1,y-1,0,x+1,y+1,0],origin=[0,0,0],transform=[1,0,0,0,0,1,0,0,0,0,1,0,x,y,0,1],color=[[1,.1,.1],[.1,1,.1],[.1,.1,1],[1,1,.1]][i%4])
  o['url']='shared.bin' if shared else f'geometry-{i}.bin';objects.append(o)
  if not (out/o['url']).exists():
   raw=bytearray((base/source['url']).read_bytes())
   if version==1:raw[4:8]=(1).to_bytes(4,'little')
   (out/o['url']).write_bytes(raw)
 m.update(name=name,objects=objects,objectCount=count,sourceObjectCount=count,bounds=[min(o['bounds'][0] for o in objects),min(o['bounds'][1] for o in objects),0,max(o['bounds'][3] for o in objects),max(o['bounds'][4] for o in objects),0],geometryBytes=source['bytes']*(1 if shared else count),triangles=source['triangles']*count,vertices=source['vertices']*count)
 (out/'manifest.json').write_text(json.dumps(m))
 print(name,count,'placements',count*source['triangles'],'triangles',m['geometryBytes'],'stored bytes')
