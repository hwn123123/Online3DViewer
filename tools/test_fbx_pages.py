#!/usr/bin/env python3
"""Compare bounded FBX mesh pages with whole-scene geometry and materials."""
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import zlib

ROOT = Path(__file__).resolve().parent.parent


def prop(tag, value):
    if tag == 'S':
        data = value.encode(); return b'S'+struct.pack('<I',len(data))+data
    if tag == 'R':
        return b'R'+struct.pack('<I',len(value))+value
    if tag in 'di':
        data = struct.pack('<'+tag*len(value),*value); compressed=zlib.compress(data)
        return tag.encode()+struct.pack('<III',len(value),1,len(compressed))+compressed
    return tag.encode()+struct.pack('<'+{'L':'q','I':'i','D':'d'}[tag],value)


def node(name, values=(), children=()):
    return name, values, children


def write_fixture(path, version):
    wide=version>=7500; null=bytes(25 if wide else 13)
    def encode(n, start):
        name,values,children=n; name=name.encode(); data=b''.join(prop(*v) for v in values)
        size=len(null)+len(name)+len(data); body=b''
        for child in children:
            value=encode(child,start+size+len(body)); body+=value
        if children: body+=null
        end=start+size+len(body)
        return struct.pack('<QQQB' if wide else '<IIIB',end,len(values),len(data),len(name))+name+data+body
    def p(name, kind, values):
        return node('P',[('S',name),('S',kind),('S',''),('S','A')]+[('D',v) for v in values])
    def model(i,name,translation,scale=(1,1,1),visibility=1):
        return node('Model',[('L',i),('S','Model::'+name),('S','Mesh' if i!=100 else 'Null')],[node('Properties70',children=[p('Lcl Translation','Lcl Translation',translation),p('Lcl Scaling','Lcl Scaling',scale),p('Visibility','Visibility',[visibility])])])
    def mesh(i,name,offset):
        return node('Geometry',[('L',i),('S','Geometry::'+name),('S','Mesh')],[node('Vertices',[('d',[offset,0,0,offset+2,0,0,offset+2,2,0,offset,2,0])]),node('PolygonVertexIndex',[('i',[0,1,-3,0,2,-4])]),node('LayerElementUV',[('I',0)],[node('MappingInformationType',[('S','ByPolygonVertex')]),node('ReferenceInformationType',[('S','Direct')]),node('UV',[('d',[0,0,1,0,1,1,0,0,1,1,0,1])])]),node('LayerElementMaterial',[('I',0)],[node('MappingInformationType',[('S','AllSame')]),node('ReferenceInformationType',[('S','IndexToDirect')]),node('Materials',[('i',[0])])]),node('Layer',[('I',0)],[node('LayerElement',children=[node('Type',[('S','LayerElementUV')]),node('TypedIndex',[('I',0)])]),node('LayerElement',children=[node('Type',[('S','LayerElementMaterial')]),node('TypedIndex',[('I',0)])])])])
    def material(i,name,color):
        return node('Material',[('L',i),('S','Material::'+name),('S','')],[node('ShadingModel',[('S','phong')]),node('Properties70',children=[p('DiffuseColor','Color',color)])])
    image=(ROOT/'test/testfiles/obj/cube_texture.png').read_bytes()
    objects=[model(100,'Parent',(10,20,30)),model(101,'VisibleA',(1,0,0)),model(102,'HiddenB',(0,3,0),visibility=0),model(103,'MirroredInstance',(0,0,4),(-1,2,1)),mesh(201,'A',0),mesh(202,'B',4),material(301,'Red',(1,.2,.1)),material(302,'Blue',(.1,.2,1)),node('Texture',[('L',401),('S','Texture::Grid'),('S','')],[node('Type',[('S','TextureVideoClip')]),node('FileName',[('S','cube_texture.png')]),node('RelativeFilename',[('S','cube_texture.png')])]),node('Video',[('L',402),('S','Video::Grid'),('S','Clip')],[node('Filename',[('S','cube_texture.png')]),node('Content',[('R',image)])])]
    connections=[('OO',100,0),('OO',101,100),('OO',102,100),('OO',103,100),('OO',201,101),('OO',201,103),('OO',202,102),('OO',301,101),('OO',301,103),('OO',302,102),('OO',402,401),('OP',401,301,'DiffuseColor'),('OP',401,302,'DiffuseColor')]
    roots=[node('FBXHeaderExtension',children=[node('FBXVersion',[('I',version)])]),node('Objects',children=objects),node('Connections',children=[node('C',[('S',c[0]),('L',c[1]),('L',c[2])]+([('S',c[3])] if len(c)>3 else [])) for c in connections])]
    data=b'Kaydara FBX Binary  \0\x1a\0'+struct.pack('<I',version)
    for root in roots:data+=encode(root,len(data))
    path.write_bytes(data+null)


def signature(directory):
    d=json.loads((directory/'manifest.json').read_text()); assert d['complete'] and not d['unsupported'],d
    materials={}
    for m in d['materials']:
        m=dict(m); i=m.pop('index')
        for key in ['texture','normalTexture','bumpTexture']:
            if m[key]:
                m[key]=dict(m[key]); m[key]['url']=hashlib.sha256((directory/m[key]['url']).read_bytes()).hexdigest()
        materials[i]=json.dumps(m,sort_keys=True)
    faces=Counter(); names=Counter(); ids={}; totals=0
    for o in d['objects']:
        data=(directory/o['url']).read_bytes(); _,v,n,ni,nl,c,uv,_=struct.unpack_from('<8I',data); assert v==2
        vertices=list(struct.iter_unpack('<3f',data[32:32+n*12])); indices=struct.unpack_from('<'+str(ni)+'I',data,32+n*24)
        normals=list(struct.iter_unpack('<3f',data[32+n*12:32+n*24])); uv_start=32+n*24+ni*4+nl*12+c*n*12
        uvs=list(struct.iter_unpack('<2f',data[uv_start:uv_start+uv*n*8])) if uv else [(0,0)]*n
        for part in o['parts']:
            assert part['start']%3==0 and part['end']<=ni
            names[part['name']]+=(part['end']-part['start'])//3
            ids.setdefault(part['name'],set()).add(part['id'])
            for i in range(part['start'],part['end'],3):
                # 1 mm at typical metre scale, only to absorb per-block float origins.
                values=[]
                for index in indices[i:i+3]:
                    values.extend(round(vertices[index][k]+o['origin'][k],3) for k in range(3))
                    values.extend(round(x,3) for x in normals[index]+uvs[index])
                faces[(part['name'],bool(o['visible']),materials.get(o['materialIndex']),tuple(values))]+=1
                totals+=1
    assert totals==d['triangles']; return d,faces,names,ids


def main():
    cli=ROOT/'build/ios/mesh-stream'
    with tempfile.TemporaryDirectory(prefix='o3dv-fbx-pages-') as temp:
        root=Path(temp); fixtures=[]
        for version in [7400,7700]:
            source=root/f'hierarchy-{version}.fbx';write_fixture(source,version);fixtures.append(source)
        fixtures.append(ROOT/'website/assets/models/Y_Bot.fbx')
        for i,source in enumerate(fixtures):
            outputs=[]
            for mode in ['whole','paged']:
                output=root/f'{i}-{mode}';env={**os.environ,('O3DV_TEST_FBX_WHOLE' if mode=='whole' else 'O3DV_TEST_FBX_PAGE_BYTES'):'1'}
                result=subprocess.run([str(cli),str(source),str(output)],env=env,capture_output=True,text=True)
                assert result.returncode==0,(source,mode,result.stderr)
                outputs.append(signature(output));assert not (output/'.fbx-pages').exists()
            whole,paged=outputs
            assert paged[0]['reader']=='ufbx-pages-1',source
            for key in ['triangles','lineSegments','sourceObjectCount']:assert whole[0][key]==paged[0][key],(source,key)
            assert whole[2]==paged[2] and whole[1]==paged[1],(source,'geometry/material/visibility differs',sum((whole[1]-paged[1]).values()),sum((paged[1]-whole[1]).values()))
            assert all(len(v)==1 for v in paged[3].values()),paged[3]
            if i<2:
                assert paged[0]['triangles']==6 and paged[0]['sourceObjectCount']==3
                assert len(list((root/f'{i}-paged').glob('texture-*')))==1,'Embedded textures were duplicated'
            print('PASS paged geometry, instances, hierarchy, UVs, normals, visibility, materials:',source.name)
        source=fixtures[0];out=root/'cancelled'
        result=subprocess.run([str(cli),str(source),str(out)],env={**os.environ,'O3DV_TEST_FBX_PAGE_BYTES':'1','O3DV_TEST_CANCEL_AFTER_READY':'1'},capture_output=True,text=True)
        assert result.returncode==1 and '取消' in result.stderr,result
        assert not (out/'.fbx-pages').exists()
        print('PASS cancellation between pages releases all temporary parser files')

if __name__=='__main__':main()
