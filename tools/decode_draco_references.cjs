// Reference transcoder uses the unmodified upstream WASM decoder, never the native library.
const fs=require('fs'),path=require('path');
const root='build/ios/draco-stream-tests';
const factory=require('../'+root+'/draco3d/draco_decoder_nodejs.js');
function glb(file,doc,data){doc.buffers=[{byteLength:data.length}];let text=Buffer.from(JSON.stringify(doc));text=Buffer.concat([text,Buffer.alloc((4-text.length%4)%4,32)]);data=Buffer.concat([data,Buffer.alloc((4-data.length%4)%4)]);const out=Buffer.alloc(28+text.length+data.length);out.writeUInt32LE(0x46546c67);out.writeUInt32LE(2,4);out.writeUInt32LE(out.length,8);out.writeUInt32LE(text.length,12);out.writeUInt32LE(0x4e4f534a,16);text.copy(out,20);out.writeUInt32LE(data.length,20+text.length);out.writeUInt32LE(0x004e4942,24+text.length);data.copy(out,28+text.length);fs.writeFileSync(file,out);}
(async()=>{const module=await factory({});const records=[];
 const inputs=['test/testfiles/gltf/Box/glTF-Draco/Box.gltf',...JSON.parse(fs.readFileSync(root+'/official/sources.json')).map(r=>r.source)];
 for(const file of inputs){const folder=path.dirname(file),doc=JSON.parse(fs.readFileSync(file)),buffers=(doc.buffers||[]).map(b=>b.uri.startsWith('data:')?Buffer.from(b.uri.split(',')[1],'base64'):fs.readFileSync(path.join(folder,decodeURIComponent(b.uri))));
  const bases=[];const output=[];let size=0;for(const b of buffers){const pad=(4-size%4)%4;output.push(Buffer.alloc(pad));size+=pad;bases.push(size);output.push(b);size+=b.length;}
  const views=structuredClone(doc.bufferViews||[]);for(const v of doc.bufferViews||[]){v.byteOffset=(v.byteOffset||0)+bases[v.buffer];v.buffer=0;}
  function append(data,component,type,count){const pad=(4-size%4)%4;output.push(Buffer.alloc(pad));size+=pad;const view=doc.bufferViews.length;doc.bufferViews.push({buffer:0,byteOffset:size,byteLength:data.length});output.push(data);size+=data.length;const index=doc.accessors.length;doc.accessors.push({bufferView:view,componentType:component,type,count});return index;}
  let faces=0;
  for(const mesh of doc.meshes||[])for(const p of mesh.primitives){const ext=p.extensions?.KHR_draco_mesh_compression;if(!ext)continue;
   const v=views[ext.bufferView],compressed=buffers[v.buffer].subarray(v.byteOffset||0,(v.byteOffset||0)+v.byteLength);
   const input=new module.DecoderBuffer();input.Init(new Int8Array(compressed),compressed.length);const decoder=new module.Decoder(),decoded=new module.Mesh();const status=decoder.DecodeBufferToMesh(input,decoded);if(!status.ok())throw Error(file+': '+status.error_msg());faces+=decoded.num_faces();
   let indices;if(p.mode===5){const data=new module.DracoInt32Array();decoder.GetTriangleStripsFromMesh(decoded,data);indices=new Uint32Array(data.size());for(let i=0;i<indices.length;i++)indices[i]=data.GetValue(i);module.destroy(data);}
   else{const count=decoded.num_faces()*3,ptr=module._malloc(count*4);decoder.GetTrianglesUInt32Array(decoded,count*4,ptr);indices=new Uint32Array(module.HEAPU32.buffer,ptr,count).slice();module._free(ptr);}
   p.indices=append(Buffer.from(indices.buffer),5125,'SCALAR',indices.length);
   for(const [semantic,id] of Object.entries(ext.attributes)){const descriptor=doc.accessors[p.attributes[semantic]],attribute=decoder.GetAttributeByUniqueId(decoded,id),components=attribute.num_components(),n=decoded.num_points()*components;
    const joints=semantic.startsWith('JOINTS_'),bytes=joints?2:4,ptr=module._malloc(n*bytes);if(!decoder.GetAttributeDataArrayForAllPoints(decoded,attribute,joints?module.DT_UINT16:module.DT_FLOAT32,n*bytes,ptr))throw Error('Reference attribute read failed');
    const data=Buffer.from(new Uint8Array(module.HEAPU8.buffer,ptr,n*bytes));module._free(ptr);p.attributes[semantic]=append(data,joints?5123:5126,descriptor.type,decoded.num_points());
   }
   module.destroy(decoded);module.destroy(decoder);module.destroy(input);delete p.extensions.KHR_draco_mesh_compression;if(!Object.keys(p.extensions).length)delete p.extensions;
  }
  for(const key of ['extensionsRequired','extensionsUsed'])if(doc[key]){doc[key]=doc[key].filter(n=>n!=='KHR_draco_mesh_compression');if(!doc[key].length)delete doc[key];}
  // Reference Box belongs under the test output; do not write into upstream source fixtures.
  const target=file.startsWith('test/')?root+'/official/Box/Box-reference.glb':file.replace(/\.gltf$/,'-reference.glb');fs.mkdirSync(path.dirname(target),{recursive:true});glb(target,doc,Buffer.concat(output));records.push({source:file,reference:target,faces});console.log('Reference',file,faces,'faces');
 }
 fs.writeFileSync(root+'/official-references.json',JSON.stringify(records,null,2)+'\n');
})().catch(e=>{console.error(e);process.exit(1)});
