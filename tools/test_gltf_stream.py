#!/usr/bin/env python3
"""Independent glTF 2.0 accessor/topology/transform reference for native caches."""
import argparse
import base64
import copy
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import struct
import subprocess
import time
import zlib
from urllib.parse import unquote

ROOT=Path(__file__).resolve().parent.parent
OUT=ROOT/'build/ios/gltf-stream-tests'
IDENTITY=[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]
AXIS=[1,0,0,0,0,0,1,0,0,-1,0,0,0,0,0,1]


def multiply(a,b):
    return [sum(a[k*4+r]*b[c*4+k] for k in range(4)) for c in range(4) for r in range(4)]


def position(matrix,p):
    return tuple(sum(matrix[c*4+r]*p[c] for c in range(3))+matrix[12+r] for r in range(3))


def local(node):
    if 'matrix' in node:return node['matrix']
    x,y,z,w=node.get('rotation',[0,0,0,1]);sx,sy,sz=node.get('scale',[1,1,1]);tx,ty,tz=node.get('translation',[0,0,0])
    return [(1-2*(y*y+z*z))*sx,2*(x*y+z*w)*sx,2*(x*z-y*w)*sx,0,
            2*(x*y-z*w)*sy,(1-2*(x*x+z*z))*sy,2*(y*z+x*w)*sy,0,
            2*(x*z+y*w)*sz,2*(y*z-x*w)*sz,(1-2*(x*x+y*y))*sz,0,tx,ty,tz,1]


def load(path):
    data=path.read_bytes();binary=None
    if data[:4]==b'glTF':
        n,kind=struct.unpack_from('<II',data,12);doc=json.loads(data[20:20+n]);at=20+n
        if at<len(data):length,kind=struct.unpack_from('<II',data,at);binary=data[at+8:at+8+length]
    else:doc=json.loads(data)
    buffers=[]
    for buf in doc.get('buffers',[]):
        uri=buf.get('uri')
        buffers.append(binary if uri is None else base64.b64decode(uri.split(',',1)[1]) if uri.startswith('data:') else (path.parent/unquote(uri)).read_bytes())
    return doc,buffers


def accessor(doc,buffers,index):
    a=doc['accessors'][index];components={'SCALAR':1,'VEC2':2,'VEC3':3,'VEC4':4,'MAT4':16}[a['type']]
    codes={5120:'b',5121:'B',5122:'h',5123:'H',5125:'I',5126:'f'};code=codes[a['componentType']];size=struct.calcsize('<'+code)
    def read(view,offset,count,stride=None,fmt=code,width=components):
        v=doc['bufferViews'][view];raw=buffers[v['buffer']];start=v.get('byteOffset',0)+offset
        return [struct.unpack_from('<'+fmt*width,raw,start+i*(stride or width*struct.calcsize('<'+fmt))) for i in range(count)]
    values=[(0,)*components]*a['count']
    if 'bufferView' in a:
        v=doc['bufferViews'][a['bufferView']]
        values=read(a['bufferView'],a.get('byteOffset',0),a['count'],v.get('byteStride'))
    if 'sparse' in a:
        s=a['sparse'];indices=s['indices'];overrides=s['values']
        ids=read(indices['bufferView'],indices.get('byteOffset',0),s['count'],fmt=codes[indices['componentType']],width=1)
        replacements=read(overrides['bufferView'],overrides.get('byteOffset',0),s['count'])
        for i,value in zip(ids,replacements):values[i[0]]=value
    if a.get('normalized') and code!='f':
        scale={5120:127,5121:255,5122:32767,5123:65535,5125:4294967295}[a['componentType']]
        values=[tuple(max(-1,x/scale) for x in v) for v in values]
    return values


def primitive_indices(mode,ids):
    if mode==0:return [(x,) for x in ids]
    if mode==1:return [tuple(ids[i:i+2]) for i in range(0,len(ids),2)]
    if mode==2:return [(ids[i],ids[(i+1)%len(ids)]) for i in range(len(ids))]
    if mode==3:return list(zip(ids,ids[1:]))
    if mode==4:return [tuple(ids[i:i+3]) for i in range(0,len(ids),3)]
    if mode==5:return [(ids[i-1],ids[i-2],ids[i]) if i%2 else (ids[i-2],ids[i-1],ids[i]) for i in range(2,len(ids))]
    if mode==6:return [(ids[0],ids[i-1],ids[i]) for i in range(2,len(ids))]
    raise AssertionError(mode)


def reference(path):
    d,b=load(path);result=[]
    def walk(index,parent):
        node=d['nodes'][index];world=multiply(parent,local(node))
        if 'mesh' in node:
            mesh=d['meshes'][node['mesh']]
            for pi,p in enumerate(mesh['primitives']):
                points=accessor(d,b,p['attributes']['POSITION'])
                ids=[x[0] for x in accessor(d,b,p['indices'])] if 'indices' in p else list(range(len(points)))
                weights=node.get('weights',mesh.get('weights',[0]*len(p.get('targets',[]))))
                for weight,target in zip(weights,p.get('targets',[])):
                    if weight and 'POSITION' in target:
                        delta=accessor(d,b,target['POSITION']);points=[tuple(x[k]+weight*y[k] for k in range(3)) for x,y in zip(points,delta)]
                assert 'skin' not in node,'Skin fixtures use an explicit independently baked reference'
                matrix=multiply(AXIS,world);points=[position(matrix,x) for x in points]
                mode=p.get('mode',4);kind='points' if mode==0 else 'lines' if mode<4 else 'triangles'
                for primitive in primitive_indices(mode,ids):result.append((index,pi,kind,tuple(v for i in primitive for v in points[i])))
        for child in node.get('children',[]):walk(child,world)
    scene=d.get('scene',0)
    for index in d['scenes'][scene]['nodes']:walk(index,IDENTITY)
    return result


def cached(directory):
    d=json.loads((directory/'manifest.json').read_text());result=[];unique={}
    assert d['complete'] and d['reader']=='gltf-stream-1' and not d['unsupported']
    for item in d['objects']:
        raw=(directory/item['url']).read_bytes();magic,version,n,index_count,lines,colors,uv,flags=struct.unpack_from('<8I',raw)
        assert magic==0x3144334f and version==3 and not lines
        assert len(raw)==item['bytes']==32+n*(24+colors*16+(uv&1)*8+((uv>>1)&1)*8+(flags&1)*16)+index_count*4
        assert n==index_count<=24576 and all(math.isfinite(x[0]) for x in struct.iter_unpack('<f',raw[32:32+n*24]))
        points=list(struct.iter_unpack('<3f',raw[32:32+n*12]));indices=struct.unpack_from('<'+'I'*index_count,raw,32+n*24)
        assert all(i<n for i in indices)
        points=[position(item['transform'],[p[k]+item['origin'][k] for k in range(3)]) for p in points]
        kind=item['drawMode'];width={'triangles':3,'lines':2,'points':1}[kind]
        for at in range(0,index_count,width):result.append((item['sourceNode'],item['primitiveIndex'],kind,tuple(v for i in indices[at:at+width] for v in points[i])))
        unique[item['url']]=len(raw)
    assert sum(unique.values())==d['geometryBytes']
    assert sum(r[2]=='triangles' for r in result)==d['triangles']
    assert sum(r[2]=='lines' for r in result)==d['lineSegments']
    assert sum(r[2]=='points' for r in result)==d['points']
    return d,result


def write_glb(path,doc,data):
    doc=copy.deepcopy(doc);doc['buffers']=[{'byteLength':len(data)}]
    text=json.dumps(doc,separators=(',',':')).encode();text+=b' '*((-len(text))%4)
    data+=b'\0'*((-len(data))%4)
    path.write_bytes(struct.pack('<III',0x46546c67,2,28+len(text)+len(data))+struct.pack('<II',len(text),0x4e4f534a)+text+struct.pack('<II',len(data),0x004e4942)+data)


def fixtures():
    source=OUT/'sources';source.mkdir(parents=True,exist_ok=True)
    # Interleaved sparse positions: override values have packed stride 12, base has stride 40.
    data=b''.join(struct.pack('<10f',*p,0,0,1,0,0,1,1) for p in [(0,0,0),(1,0,0),(0,1,0)])+struct.pack('<I3f',2,0,2,0)
    doc={'asset':{'version':'2.0'},'buffers':[{'byteLength':len(data)}],
         'bufferViews':[{'buffer':0,'byteOffset':0,'byteLength':120,'byteStride':40},{'buffer':0,'byteOffset':120,'byteLength':4},{'buffer':0,'byteOffset':124,'byteLength':12}],
         'accessors':[{'bufferView':0,'componentType':5126,'count':3,'type':'VEC3','sparse':{'count':1,'indices':{'bufferView':1,'componentType':5125},'values':{'bufferView':2}}}],
         'meshes':[{'primitives':[{'attributes':{'POSITION':0}}]}],
         'nodes':[{'name':'nested parent','translation':[2,3,4],'children':[1,2]},
                  {'name':'mirrored','mesh':0,'scale':[-2,3,.5]},{'name':'sheared','mesh':0,'matrix':[1,.2,0,0,.3,1,0,0,0,0,1,0,-2,0,1,1]}],
         'scenes':[{'nodes':[0]}],'scene':0}
    write_glb(source/'sparse-instances.glb',doc,data)
    # Independent baked geometry avoids the reference loader's sparse/interleaved clone and shear decomposition.
    baked_doc={'asset':{'version':'2.0'},'bufferViews':[{'buffer':0,'byteLength':72},{'buffer':0,'byteOffset':72,'byteLength':72}],
               'accessors':[{'bufferView':i,'componentType':5126,'count':6,'type':'VEC3'} for i in range(2)],
               'meshes':[{'primitives':[{'attributes':{'POSITION':0,'NORMAL':1}}]}],
               'nodes':[{'mesh':0}],'scenes':[{'nodes':[0]}],'scene':0}
    baked_positions=[2,3,4,2,9,4,0,3,4,0,3,5,1,3.2,5,.6,5,5]
    write_glb(source/'sparse-baked.glb',baked_doc,struct.pack('<18f',*baked_positions)+struct.pack('<18f',*([0,0,1]*6)))
    # Default morph weights and distinct per-node overrides must not share the wrong cached geometry.
    points=struct.pack('<9f',0,0,0,1,0,0,0,1,0);delta=struct.pack('<9f',0,0,1,0,0,2,0,0,3)
    morph={'asset':{'version':'2.0'},'buffers':[{'byteLength':72}],'bufferViews':[{'buffer':0,'byteLength':36},{'buffer':0,'byteOffset':36,'byteLength':36}],
           'accessors':[{'bufferView':i,'componentType':5126,'count':3,'type':'VEC3'} for i in range(2)],
           'meshes':[{'weights':[.5],'primitives':[{'attributes':{'POSITION':0},'targets':[{'POSITION':1}]}]}],
           'nodes':[{'mesh':0,'name':'default morph'},{'mesh':0,'translation':[2,0,0],'weights':[.75],'name':'override morph'}],
           'scenes':[{'nodes':[0,1]}],'scene':0}
    write_glb(source/'morph.glb',morph,points+delta)
    # Baked independent reference: joint translates all vertices by +2 X in glTF coordinates.
    skin=copy.deepcopy(morph);skin['nodes']=[{'mesh':0,'skin':0},{'translation':[2,0,0]}]
    skin['meshes']=[{'primitives':[{'attributes':{'POSITION':0,'JOINTS_0':1,'WEIGHTS_0':2}}]}]
    skin['skins']=[{'joints':[1]}];skin['scenes']=[{'nodes':[0,1]}]
    skin['bufferViews']=[{'buffer':0,'byteLength':36},{'buffer':0,'byteOffset':36,'byteLength':12},{'buffer':0,'byteOffset':48,'byteLength':48}]
    skin['accessors']=[{'bufferView':0,'componentType':5126,'count':3,'type':'VEC3'},
                       {'bufferView':1,'componentType':5121,'count':3,'type':'VEC4'},
                       {'bufferView':2,'componentType':5126,'count':3,'type':'VEC4'}]
    write_glb(source/'skin.glb',skin,points+b'\0'*12+struct.pack('<12f',*([1,0,0,0]*3)))
    baked=copy.deepcopy(skin);baked['nodes']=[{'mesh':0,'translation':[2,0,0]}];baked.pop('skins');baked['scenes']=[{'nodes':[0]}]
    baked['meshes'][0]['primitives'][0]['attributes']={'POSITION':0}
    write_glb(source/'skin-baked.glb',baked,points+b'\0'*12+struct.pack('<12f',*([1,0,0,0]*3)))
    def png(path,pixels):
        def chunk(tag,data):return struct.pack('>I',len(data))+tag+data+struct.pack('>I',zlib.crc32(tag+data)&0xffffffff)
        raw=b''.join(b'\0'+bytes(pixels[y*8:y*8+8]) for y in range(2))
        path.write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',2,2,8,6,0,0,0))+chunk(b'IDAT',zlib.compress(raw))+chunk(b'IEND',b''))
    png(source/'color.png',[255,0,0,255,0,255,0,0,0,0,255,128,255,255,255,255])
    png(source/'normal.png',[128,128,255,255]*4)
    png(source/'surface.png',[220,128,64,255,128,255,255,255,255,64,0,255,255,255,128,255])
    binary=bytearray();views=[];accessors=[]
    def attribute(values,width,kind='f',component=5126):
        while len(binary)%4:binary.append(0)
        at=len(binary);binary.extend(struct.pack('<'+kind*len(values),*values));views.append({'buffer':0,'byteOffset':at,'byteLength':len(binary)-at})
        accessors.append({'bufferView':len(views)-1,'componentType':component,'count':len(values)//width,'type':{1:'SCALAR',2:'VEC2',3:'VEC3',4:'VEC4'}[width]});return len(accessors)-1
    attrs={'POSITION':attribute([0,0,0,1,0,0,1,1,0,0,1,0],3),'NORMAL':attribute([0,0,1]*4,3),
           'TEXCOORD_0':attribute([0,0,1,0,1,1,0,1],2),'TEXCOORD_1':attribute([1,0,1,1,0,1,0,0],2),
           'COLOR_0':attribute([1,.8,.6,.25,1,.8,.6,.5,1,.8,.6,.75,1,.8,.6,1],4),'TANGENT':attribute([1,0,0,1]*4,4)}
    indices=attribute([0,1,2,0,2,3],1,'H',5123)
    materials=[]
    for mode in ['OPAQUE','MASK','BLEND']:
        materials.append({'name':mode,'doubleSided':True,'alphaMode':mode,'alphaCutoff':.4,
                          'pbrMetallicRoughness':{'baseColorFactor':[.8,.9,1,.7],'baseColorTexture':{'index':0},'metallicFactor':0,'roughnessFactor':.8}})
    materials.append({'name':'UV1/PBR/transform','doubleSided':True,'pbrMetallicRoughness':{'baseColorTexture':{'index':0,'texCoord':1,'extensions':{'KHR_texture_transform':{'offset':[.25,0],'rotation':.3,'scale':[.5,.75]}}},'metallicRoughnessTexture':{'index':2}},
                      'normalTexture':{'index':1},'occlusionTexture':{'index':2,'texCoord':1,'strength':.5},'emissiveTexture':{'index':0},'emissiveFactor':[.1,.2,.3]})
    material_doc={'asset':{'version':'2.0'},'extensionsUsed':['KHR_texture_transform'],'buffers':[{'uri':'material.bin','byteLength':len(binary)}],
                  'bufferViews':views,'accessors':accessors,'images':[{'uri':n} for n in ['color.png','normal.png','surface.png']],
                  'samplers':[{'magFilter':9728,'minFilter':9728,'wrapS':33648,'wrapT':10497}],
                  'textures':[{'source':i,'sampler':0} for i in range(3)],'materials':materials,
                  'meshes':[{'primitives':[{'attributes':attrs,'indices':indices,'material':i}]} for i in range(4)],
                  'nodes':[{'mesh':i,'translation':[i*1.25,0,0]} for i in range(4)],'scenes':[{'nodes':[0,1,2,3]}],'scene':0}
    (source/'material.bin').write_bytes(binary);(source/'materials.gltf').write_text(json.dumps(material_doc))
    return source


def big_fixture(source,triangles=1048576):
    # 36 MiB BIN data; append directly to GLB without retaining the binary in Python memory.
    doc={'asset':{'version':'2.0'},'buffers':[{'byteLength':triangles*36}],
         'bufferViews':[{'buffer':0,'byteLength':triangles*36}],
         'accessors':[{'bufferView':0,'componentType':5126,'count':triangles*3,'type':'VEC3'}],
         'meshes':[{'primitives':[{'attributes':{'POSITION':0}}]}],'nodes':[{'mesh':0}],
         'scenes':[{'nodes':[0]}],'scene':0}
    text=json.dumps(doc,separators=(',',':')).encode();text+=b' '*((-len(text))%4)
    path=source/'large.glb'
    with path.open('wb') as out:
        out.write(struct.pack('<III',0x46546c67,2,28+len(text)+triangles*36));out.write(struct.pack('<II',len(text),0x4e4f534a));out.write(text);out.write(struct.pack('<II',triangles*36,0x004e4942))
        buffer=bytearray()
        for i in range(triangles):
            x,y=i%1024,i//1024;buffer.extend(struct.pack('<9f',x,0,y,x+.75,0,y,x+.25,0,y+.75))
            if len(buffer)>1024*1024:out.write(buffer);buffer.clear()
        out.write(buffer)
    return path


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--large',action='store_true')
    parser.add_argument('--cli',type=Path,default=ROOT/'build/ios/gltf-stream');args=parser.parse_args()
    OUT.mkdir(parents=True,exist_ok=True);source=fixtures()
    paths=sorted((ROOT/'test/testfiles/gltf').rglob('*.gltf'))+sorted((ROOT/'test/testfiles/gltf').rglob('*.glb'))+[source/n for n in ['morph.glb','skin-baked.glb','skin.glb','sparse-instances.glb','sparse-baked.glb','materials.gltf']]
    results=[];cli=str(args.cli)
    for number,path in enumerate(paths):
        directory=OUT/'caches'/f'{number:03d}'
        if directory.exists():shutil.rmtree(directory)
        started=time.monotonic();run=subprocess.run([cli,str(path),str(directory)],capture_output=True,text=True,timeout=120)
        assert run.returncode==0,(path,run.stderr)
        manifest,actual=cached(directory)
        if 'glTF-Draco' in path.parts:expected=reference(ROOT/'build/ios/draco-stream-tests/official/Box/Box-reference.glb')
        elif path.name=='skin.glb':expected=reference(source/'skin-baked.glb')
        else:expected=reference(path)
        assert len(actual)==len(expected),(path,len(actual),len(expected))
        for a,b in zip(actual,expected):
            assert a[:3]==b[:3],(path,a[:3],b[:3])
            assert all(math.isclose(x,y,rel_tol=3e-6,abs_tol=2e-5) for x,y in zip(a[3],b[3])),(path,a,b)
        statuses=[json.loads(line) for line in run.stdout.splitlines()]
        fractions=[s['fraction'] for s in statuses if 'fraction' in s]
        assert statuses[-1]['phase']=='complete' and all(a<=b for a,b in zip(fractions,fractions[1:]))
        if path.name=='sparse-instances.glb':assert len({p['url'] for p in manifest['objects']})==1
        if path.name=='morph.glb':assert len({p['url'] for p in manifest['objects']})==2
        row={'name':str(path.relative_to(ROOT)),'status':'passed','cache':str(directory.relative_to(ROOT)),
             'sourceBytes':path.stat().st_size,'triangles':manifest['triangles'],'lines':manifest['lineSegments'],'points':manifest['points'],
             'blocks':manifest['objectCount'],'uniqueBlocks':len({p['url'] for p in manifest['objects']}),
             'seconds':round(time.monotonic()-started,3),'footprintBytes':manifest['nativePeakFootprintBytes']}
        results.append(row);print('PASS',path.parent.name,path.name,manifest['triangles'],manifest['lineSegments'],manifest['points'],flush=True)
    if args.large:
        path=big_fixture(source);directory=OUT/'large-cache';run=subprocess.run([cli,str(path),str(directory)],capture_output=True,text=True,timeout=120)
        assert run.returncode==0,run.stderr;manifest=json.loads((directory/'manifest.json').read_text())
        assert manifest['triangles']==1048576 and manifest['nativePeakFootprintBytes']<64*1048576
        statuses=[json.loads(line) for line in run.stdout.splitlines()]
        assert statuses[0]['phase']=='ready' and statuses[0]['fraction']<.02,statuses[0]
        assert sum(p['triangles'] for p in manifest['objects'])==1048576
        results.append({'name':'generated large.glb','status':'passed','triangles':1048576,'cache':str(directory.relative_to(ROOT)),
                        'footprintBytes':manifest['nativePeakFootprintBytes'],'sourceBytes':path.stat().st_size})
        print('PASS large GLB, 1,048,576 faces, early first block, fixed geometry buffer',flush=True)
    # Construct malformed JSON references and data ranges from a real generated fixture.
    doc,bufs=load(source/'sparse-instances.glb');negatives=[]
    variants={}
    invalid=copy.deepcopy(doc);invalid['accessors'][0]['count']=2**63;variants['overflow-accessor']=invalid
    invalid=copy.deepcopy(doc);invalid['bufferViews'][0]['byteLength']=2**63;variants['overflow-view']=invalid
    invalid=copy.deepcopy(doc);invalid['nodes'][0]['children']=[0];variants['cycle']=invalid
    invalid=copy.deepcopy(doc);invalid['accessors'][0]['sparse']['indices']['byteOffset']=99999;variants['bad-sparse']=invalid
    invalid=copy.deepcopy(doc);invalid['bufferViews'][2]['byteOffset']=121;variants['unaligned-sparse']=invalid
    invalid=copy.deepcopy(doc);invalid['extensionsRequired']=['UNKNOWN_extension'];variants['required-extension']=invalid
    for name,invalid in variants.items():
        path=source/(name+'.glb');write_glb(path,invalid,bufs[0]);run=subprocess.run([cli,str(path),str(OUT/'negative'/name)],capture_output=True,text=True)
        assert run.returncode==1 and ('O3DVGLTF:1' in run.stderr or 'O3DVGLTF:4' in run.stderr),(name,run)
        negatives.append({'name':name,'error':run.stderr.strip()})
    for key,code in [('CANCEL',3),('CANCEL_AFTER_READY',3),('CRITICAL_PRESSURE',2)]:
        run=subprocess.run([cli,str(source/'sparse-instances.glb'),str(OUT/'negative'/key)],env={**os.environ,'O3DV_TEST_'+key:'1'},capture_output=True,text=True)
        assert run.returncode==1 and f'O3DVGLTF:{code}' in run.stderr,(key,run)
        negatives.append({'name':key,'error':run.stderr.strip()})
    (OUT/'native-results.json').write_text(json.dumps({'passed':True,'cases':results,'negative':negatives},ensure_ascii=False,indent=2)+'\n')
    print('PASS independent source/accessor/topology/transform comparison and cancellation/errors')


if __name__=='__main__':main()
