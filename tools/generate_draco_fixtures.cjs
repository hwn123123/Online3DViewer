// Unmodified official WASM encoder/decoder provide an independent reference for the native build.
const fs=require('fs'),path=require('path');
const base='build/ios/draco-stream-tests',out=base+'/sources';fs.mkdirSync(out,{recursive:true});
const encFactory=require('../'+base+'/draco3d/draco_encoder_nodejs.js');
const decFactory=require('../'+base+'/draco3d/draco_decoder_nodejs.js');
function glb(file,doc,data){doc={...doc,buffers:[{byteLength:data.length}]};let json=Buffer.from(JSON.stringify(doc));json=Buffer.concat([json,Buffer.alloc((4-json.length%4)%4,32)]);data=Buffer.concat([data,Buffer.alloc((4-data.length%4)%4)]);const b=Buffer.alloc(28+json.length+data.length);b.writeUInt32LE(0x46546c67);b.writeUInt32LE(2,4);b.writeUInt32LE(b.length,8);b.writeUInt32LE(json.length,12);b.writeUInt32LE(0x4e4f534a,16);json.copy(b,20);b.writeUInt32LE(data.length,20+json.length);b.writeUInt32LE(0x004e4942,24+json.length);data.copy(b,28+json.length);fs.writeFileSync(file,b);}
function bytes(array){return Buffer.from(array.buffer,array.byteOffset,array.byteLength);}
(async()=>{
 const encoder=await encFactory({}),decoder=await decFactory({});const records=[];
 function decode(compressed,ids,strip=false){
  const b=new decoder.DecoderBuffer();b.Init(new Int8Array(compressed),compressed.length);const d=new decoder.Decoder(),m=new decoder.Mesh();const status=d.DecodeBufferToMesh(b,m);if(!status.ok())throw Error(status.error_msg());
  const attrs={};for(const [name,id] of Object.entries(ids)){const a=d.GetAttributeByUniqueId(m,id);const n=m.num_points()*a.num_components(),p=decoder._malloc(n*4);if(!d.GetAttributeDataArrayForAllPoints(m,a,decoder.DT_FLOAT32,n*4,p))throw Error('Attribute decoding failed');attrs[name]=new Float32Array(decoder.HEAPF32.buffer,p,n).slice();decoder._free(p);}
  let indices;
  if(strip){const data=new decoder.DracoInt32Array();d.GetTriangleStripsFromMesh(m,data);indices=new Uint32Array(data.size());for(let i=0;i<indices.length;i++)indices[i]=data.GetValue(i);decoder.destroy(data);}
  else{const n=m.num_faces()*3,p=decoder._malloc(n*4);d.GetTrianglesUInt32Array(m,n*4,p);indices=new Uint32Array(decoder.HEAPU32.buffer,p,n).slice();decoder._free(p);}
  const points=m.num_points();decoder.destroy(m);decoder.destroy(d);decoder.destroy(b);return{attrs,indices,points};
 }
 function create(name,width,height,method=encoder.MESH_EDGEBREAKER_ENCODING,extras={}){
  const n=width*height,nfaces=(width-1)*(height-1)*2;console.log('Encoding',name,n,'points',nfaces,'faces');
  const positions=new Float32Array(n*3),normals=new Float32Array(n*3),uv=new Float32Array(n*2),colors=new Uint8Array(n*4);
  for(let y=0;y<height;y++)for(let x=0;x<width;x++){const i=y*width+x;positions.set([x/Math.max(1,width-1)*2,Math.sin(x*.1)*.05,y/Math.max(1,height-1)*2],i*3);normals.set([0,1,0],i*3);uv.set([x/Math.max(1,width-1),y/Math.max(1,height-1)],i*2);colors.set([64+x%128,128,255-y%128,64+i%192],i*4);}
  const faces=new Int32Array(nfaces*3);let at=0;for(let y=0;y<height-1;y++)for(let x=0;x<width-1;x++){const a=y*width+x;faces.set([a,a+width,a+1,a+1,a+width,a+width+1],at);at+=6;}
  const mesh=new encoder.Mesh(),builder=new encoder.MeshBuilder(),e=new encoder.Encoder();builder.AddFacesToMesh(mesh,nfaces,faces);const ids={};
  // Attribute IDs deliberately differ from accessor indices, including POSITION id 2 with only 2 accessors.
  ids.NORMAL=builder.AddFloatAttributeToMesh(mesh,encoder.NORMAL,n,3,normals);
  ids.COLOR_0=builder.AddUInt8Attribute(mesh,encoder.COLOR,n,4,colors);builder.SetNormalizedFlagForAttribute(mesh,ids.COLOR_0,true);
  ids.POSITION=builder.AddFloatAttributeToMesh(mesh,encoder.POSITION,n,3,positions);
  if(!extras.positionOnly)ids.TEXCOORD_0=builder.AddFloatAttributeToMesh(mesh,encoder.TEX_COORD,n,2,uv);
  e.SetSpeedOptions(5,5);e.SetEncodingMethod(method);e.SetAttributeQuantization(encoder.POSITION,14);e.SetAttributeQuantization(encoder.NORMAL,10);e.SetAttributeQuantization(encoder.TEX_COORD,12);
  const data=new encoder.DracoInt8Array(),size=e.EncodeMeshToDracoBuffer(mesh,data);if(size<=0)throw Error('Encoding failed');const compressed=Buffer.alloc(size);for(let i=0;i<size;i++)compressed[i]=data.GetValue(i);
  encoder.destroy(data);encoder.destroy(e);encoder.destroy(builder);encoder.destroy(mesh);
  const used=extras.positionOnly?{POSITION:ids.POSITION}:ids,decoded=decode(compressed,used,extras.strip);
  const attributes={},accessors=[{componentType:5125,count:decoded.indices.length,type:'SCALAR'}];
  for(const semantic of Object.keys(used)){
   attributes[semantic]=accessors.length;const components=decoded.attrs[semantic].length/decoded.points;
   accessors.push({componentType:semantic==='COLOR_0'?5121:5126,normalized:semantic==='COLOR_0',count:decoded.points,type:'VEC'+components});
  }
  const primitive={attributes,indices:0,mode:extras.strip?5:4,material:0,extensions:{KHR_draco_mesh_compression:{bufferView:0,attributes:used}}};
  const doc={asset:{version:'2.0',generator:'Official Draco 1.5.7 WASM validation fixture'},extensionsUsed:['KHR_draco_mesh_compression'],extensionsRequired:['KHR_draco_mesh_compression'],
   accessors,bufferViews:[{buffer:0,byteLength:compressed.length}],meshes:[{primitives:[primitive]}],
   materials:[{doubleSided:true,alphaMode:extras.opaque?'OPAQUE':'BLEND',pbrMetallicRoughness:{metallicFactor:0,roughnessFactor:.8,baseColorFactor:[.7,.9,1,1]}}],nodes:[{mesh:0,name:'decoded '+name}],scenes:[{nodes:[0]}],scene:0};
  if(extras.instances){doc.nodes=[{translation:[1,2,3],children:[1,2]},{mesh:0,scale:[-1,2,.5]},{mesh:0,translation:[3,0,1]}];doc.scenes=[{nodes:[0]}];}
  let source=compressed;
  // Mixed attributes are aligned to the decoded point order, as required by the extension.
  if(extras.mixed){const attr=new Float32Array(decoded.points*2);for(let i=0;i<decoded.points;i++)attr.set([i%2,(i%3)/2],i*2);decoded.attrs.TEXCOORD_1=attr;
   const pad=(4-source.length%4)%4,offset=source.length+pad;source=Buffer.concat([source,Buffer.alloc(pad),bytes(attr)]);doc.bufferViews.push({buffer:0,byteOffset:offset,byteLength:attr.byteLength});primitive.attributes.TEXCOORD_1=doc.accessors.length;doc.accessors.push({bufferView:1,componentType:5126,count:decoded.points,type:'VEC2'});}
  if(extras.optional)delete doc.extensionsRequired;
  glb(out+'/'+name+'.glb',doc,source);
  const ref=structuredClone(doc);delete ref.extensionsRequired;delete ref.extensionsUsed;delete ref.meshes[0].primitives[0].extensions;ref.bufferViews=[];ref.accessors=[];ref.meshes[0].primitives[0].attributes={};
  const buffers=[];let offset=0;
  function append(data,type,component,count){const index=ref.accessors.length;ref.bufferViews.push({buffer:0,byteOffset:offset,byteLength:data.length});ref.accessors.push({bufferView:index,componentType:component,count,type});buffers.push(data);offset+=data.length;return index;}
  ref.meshes[0].primitives[0].indices=append(bytes(decoded.indices),'SCALAR',5125,decoded.indices.length);
  for(const [semantic,array] of Object.entries(decoded.attrs))ref.meshes[0].primitives[0].attributes[semantic]=append(bytes(array),'VEC'+array.length/decoded.points,5126,decoded.points);
  glb(out+'/'+name+'-reference.glb',ref,Buffer.concat(buffers));fs.writeFileSync(out+'/'+name+'.drc',compressed);
  records.push({name,triangles:nfaces,points:decoded.points,compressedBytes:compressed.length,source:name+'.glb',reference:name+'-reference.glb'});
 }
 create('edgebreaker',12,10);create('sequential',12,10,encoder.MESH_SEQUENTIAL_ENCODING);
 create('sparse-ids',5,4,encoder.MESH_EDGEBREAKER_ENCODING,{positionOnly:true});
 create('mixed',8,7,encoder.MESH_EDGEBREAKER_ENCODING,{mixed:true});
 create('instances',8,7,encoder.MESH_EDGEBREAKER_ENCODING,{instances:true,optional:true});
 create('strip',8,7,encoder.MESH_EDGEBREAKER_ENCODING,{strip:true});
 if(process.argv.includes('--large'))create('large',512,1024,encoder.MESH_EDGEBREAKER_ENCODING,{opaque:true});
 fs.writeFileSync(base+'/fixtures.json',JSON.stringify(records,null,2)+'\n');console.log('PASS generated',records.length,'independent compressed/reference pairs');
})().catch(e=>{console.error(e);process.exit(1)});
