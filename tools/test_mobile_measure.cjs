// Check two-point measurement using known-size geometry and a transformed instance.
const fs = require('fs');
const {chromium} = require(process.env.O3DV_PLAYWRIGHT_MODULE || 'playwright');
const folder = 'build/ios/memory-stream-tests/fixtures/measure-test';
fs.mkdirSync(folder,{recursive:true});
const vertices = [[0,0,0],[100,0,0],[100,100,0],[0,100,0]];
const indices = [0,1,2,0,2,3];
const bytes = Buffer.alloc(32 + vertices.length*24 + indices.length*4);
[0x3144334f,1,4,6,0,0,0,0].forEach((v,i)=>bytes.writeUInt32LE(v,i*4));
vertices.forEach((p,i)=>p.forEach((v,k)=>bytes.writeFloatLE(v,32+i*12+k*4)));
vertices.forEach((p,i)=>bytes.writeFloatLE(1,32+vertices.length*12+i*12+8));
indices.forEach((n,i)=>bytes.writeUInt32LE(n,32+vertices.length*24+i*4));
fs.writeFileSync(folder+'/quad.bin',bytes);
fs.writeFileSync('build/ios/WebAssets/measure-quad.stl', `solid quad
facet normal 0 0 1
outer loop
vertex 0 0 0
vertex 100 0 0
vertex 100 100 0
endloop
endfacet
facet normal 0 0 1
outer loop
vertex 0 0 0
vertex 100 100 0
vertex 0 100 0
endloop
endfacet
endsolid quad\n`);
const object={id:'quad',index:0,name:'quad',type:'Mesh',layerIndex:0,materialIndex:-1,color:[.5,.5,.5],lineColor:[0,0,0],opacity:1,visible:true,definitionMember:false,available:true,origin:[0,0,0],bounds:[0,0,0,100,100,0],url:'quad.bin',bytes:bytes.length,vertices:4,triangles:2,lineSegments:0};
const manifest={format:'o3dv-stream-1',reader:'stl-stream-1',complete:true,name:'Known-size quad',objects:[object],objectCount:1,sourceObjectCount:1,geometryBytes:bytes.length,triangles:2,vertices:4,lineSegments:0,layers:[{index:0,id:'0',name:'Layer',visible:true}],materials:[],unsupported:[],missingFiles:[],bounds:object.bounds};
fs.writeFileSync(folder+'/manifest.json',JSON.stringify(manifest));
const transformed=structuredClone(manifest);transformed.name='Affine quad';transformed.objects[0].transform=[2,0,0,0,.5,1,0,0,0,0,1,0,1000,2000,3,1];transformed.objects[0].geometryBounds=[0,0,0,100,100,0];transformed.objects[0].bounds=[1000,2000,3,1250,2100,3];transformed.bounds=transformed.objects[0].bounds;transformed.units='mm';
fs.writeFileSync(folder+'/transformed.json',JSON.stringify(transformed));
// Three visible blocks total more than the 256 KiB display budget; selecting
// the front one must work even when its geometry was evicted after rendering.
const count=8000,large=Buffer.alloc(32+count*24+24);
[0x3144334f,1,count,6,0,0,0,0].forEach((v,i)=>large.writeUInt32LE(v,i*4));
for(let i=0;i<count;i++){const p=vertices[i%4];p.forEach((v,k)=>large.writeFloatLE(v,32+i*12+k*4));large.writeFloatLE(1,32+count*12+i*12+8);}
indices.forEach((n,i)=>large.writeUInt32LE(n,32+count*24+i*4));
const low=structuredClone(manifest);low.name='Evicted geometry';low.objects=[];low.bounds=[0,0,0,100,100,2];low.objectCount=3;low.sourceObjectCount=3;low.triangles=6;low.vertices=count*3;low.geometryBytes=large.length*3;
for(let i=0;i<3;i++){fs.writeFileSync(folder+'/large-'+i+'.bin',large);low.objects.push({...object,id:'large-'+i,index:i,url:'large-'+i+'.bin',bytes:large.length,vertices:count,origin:[0,0,i],bounds:[0,0,0,100,100,2]});}
fs.writeFileSync(folder+'/evicted.json',JSON.stringify(low));
(async()=>{
 const browser=await chromium.launch({...(process.env.O3DV_BROWSER_EXECUTABLE?{executablePath:process.env.O3DV_BROWSER_EXECUTABLE}:{}),headless:true,args:['--use-angle=swiftshader','--enable-webgl','--ignore-gpu-blocklist']});
 const page=await browser.newPage({viewport:{width:600,height:700}});const errors=[];page.on('pageerror',e=>errors.push(String(e)));
 await page.addInitScript(()=>{window.O3DVNativeDebug=true;window.events=[];window.webkit={messageHandlers:{o3dv:{postMessage:m=>window.events.push(m)}}};});
 await page.goto('http://127.0.0.1:8097/');await page.waitForFunction(()=>window.O3DVOpenStream);
 async function open(file){await page.evaluate(file=>{window.events=[];window.O3DVOpenStream(location.origin+'/models/measure-test/'+file);},file);await page.waitForFunction(()=>window.events.some(e=>e.type==='model_loaded'||e.type==='javascript_error'),null,{timeout:40000});const err=await page.evaluate(()=>window.events.find(e=>e.type==='javascript_error'));if(err)throw Error(JSON.stringify(err));await page.locator('.o3dv-measure-toggle').click();}
 async function clickVertex(point,center,count,edge=true){const [v,c]=await page.evaluate(([a,b])=>[window.O3DVProjectMeasurementPoint(a),window.O3DVProjectMeasurementPoint(b)],[point,center]);const canvas=await page.locator('#viewer').boundingBox();const dx=c[0]-v[0],dy=c[1]-v[1],d=Math.hypot(dx,dy);await page.mouse.click(canvas.x+v[0]+dx/d*5,canvas.y+v[1]+dy/d*5);await page.waitForFunction(()=>window.O3DVMeasurementDebug().candidate!==null,null,{timeout:10000});if((await state()).points.length!==count-1)throw Error('Preview changed committed points');if(!(await page.locator('.o3dv-measure-preview canvas').isVisible()))throw Error('Missing magnified preview');const preview=await page.locator('.o3dv-measure-preview canvas').evaluate(c=>{const d=c.getContext('2d').getImageData(0,0,c.width,c.height).data;let light=0,dark=0;for(let i=0;i<d.length;i+=4){if(d[i]>245&&d[i+1]>245&&d[i+2]>245)light++;if(d[i]<240&&d[i+1]<240&&d[i+2]<240)dark++;}return {light,dark};});if(preview.dark<10||(edge&&preview.light<10)){const data=await page.locator('.o3dv-measure-preview canvas').evaluate(c=>c.toDataURL());fs.writeFileSync('build/android-tests/loupe-failed.png',Buffer.from(data.split(',')[1],'base64'));throw Error('Magnifier missing model/background: '+JSON.stringify(preview));}await page.locator('.o3dv-measure-confirm').click();await page.waitForFunction(n=>window.O3DVMeasurementDebug().points.length===n,count,{timeout:5000});}
 async function state(){return page.evaluate(()=>window.O3DVMeasurementDebug());}
 await open('manifest.json');
 let initialBox=await page.locator('#viewer').boundingBox();await page.mouse.click(initialBox.x+initialBox.width*.5,initialBox.y+initialBox.height*.5);
 await page.waitForFunction(()=>window.O3DVMeasurementDebug().candidate!==null,null,{timeout:10000});
 if((await state()).points.length)throw Error('Unconfirmed candidate was saved');
 await page.mouse.move(initialBox.x+initialBox.width*.4,initialBox.y+initialBox.height*.4);await page.mouse.down();await page.mouse.move(initialBox.x+initialBox.width*.5,initialBox.y+initialBox.height*.45,{steps:3});await page.mouse.up();
 await page.waitForFunction(()=>window.O3DVMeasurementDebug().candidate===null,null,{timeout:10000});
 if(await page.locator('.o3dv-measure-confirm').isVisible())throw Error('Moving the view retained a stale candidate');
 await page.locator('.o3dv-measure-close').click();await open('manifest.json');
 console.log('PASS view movement cancels an unconfirmed point');
 await clickVertex([0,0,0],[50,50,0],1);await clickVertex([100,0,0],[50,50,0],2);
 let s=await state();let dist=Math.hypot(...s.points[0].point.map((x,i)=>x-s.points[1].point[i]));if(!s.points.every(p=>p.snapped)||Math.abs(dist-100)>1e-5)throw Error('Incorrect vertex distance '+JSON.stringify(s));
 if(!(await page.locator('.o3dv-measure-result').textContent()).includes('单位未知'))throw Error('Unknown units were silently assigned');
 await page.locator('.o3dv-measure-controls select').selectOption('mm');if(!(await page.locator('.o3dv-measure-result').textContent()).includes('100 mm'))throw Error('Unit label wrong');
 console.log('PASS known 100-unit edge, vertex snapping and unknown-unit confirmation');
 await page.locator('.o3dv-measure-undo').click();s=await state();if(s.points.length!==1||!s.points[0].snapped)throw Error('Undo did not preserve first point');
 await clickVertex([100,0,0],[50,50,0],2);s=await state();dist=Math.hypot(...s.points[0].point.map((x,i)=>x-s.points[1].point[i]));if(Math.abs(dist-100)>1e-5)throw Error('Measurement changed after undo');
 console.log('PASS undo and reselect');
 await page.locator('.o3dv-measure-clear').click();if((await state()).points.length)throw Error('Clear failed');
 await open('transformed.json');if((await state()).unit!=='mm')throw Error('File units not applied');await clickVertex([1000,2000,3],[1125,2050,3],1);await clickVertex([1200,2000,3],[1125,2050,3],2);s=await state();dist=Math.hypot(...s.points[0].point.map((x,i)=>x-s.points[1].point[i]));if(!s.points.every(p=>p.snapped)||Math.abs(dist-200)>1e-5)throw Error('Incorrect transformed measurement '+JSON.stringify(s));
 console.log('PASS transformed instance world coordinates and recognized units');
 await page.locator('.o3dv-measure-close').click();if((await state()).active||(await state()).points.length)throw Error('Close failed');
 await page.evaluate(()=>window.O3DVSetMemoryPolicy({geometryBytes:262144,textureBytes:1048576,framePixels:1000000}));
 await open('evicted.json');await page.evaluate(()=>window.O3DVTestEvictGeometry());let reads=(await state()).readRequests;const box=await page.locator('#viewer').boundingBox();
 await clickVertex([0,0,2],[50,50,2],1);
 s=await state();if(s.readRequests<=reads)throw Error('Evicted picking did not read geometry again: '+JSON.stringify(s));
 if(!s.points[0].snapped||Math.abs(s.points[0].point[2]-2)>1e-6)throw Error('Evicted placement lost world transform: '+JSON.stringify(s));
 console.log('PASS measurement reads an evicted block under a 256 KiB budget');
 await page.locator('.o3dv-measure-clear').click();await page.evaluate(()=>window.O3DVTestEvictGeometry());
 await page.route('**/large-*.bin',async route=>{await new Promise(resolve=>setTimeout(resolve,500));try{await route.continue();}catch{/* navigation may cancel the delayed request */}});
 await page.mouse.click(box.x+box.width*.5,box.y+box.height*.5);
 await page.locator('.o3dv-measure-clear').click();await page.waitForTimeout(1500);
 if((await state()).points.length || (await state()).candidate)throw Error('Cancelled asynchronous pick reappeared');
 await page.unroute('**/large-*.bin');console.log('PASS clear rejects stale asynchronous picks');
 await page.locator('.o3dv-measure-close').click();
 if(fs.existsSync('build/ios/memory-stream-tests/fixtures/measure-rhino/manifest.json')) {
  await page.evaluate(()=>{window.events=[];window.O3DVOpenStream(location.origin+'/models/measure-rhino/manifest.json');});
  await page.waitForFunction(()=>window.events.some(e=>e.type==='model_loaded'||e.type==='javascript_error'),null,{timeout:40000});
  await page.locator('.o3dv-measure-toggle').click();await clickVertex([0,0,0],[50,50,0],1);await clickVertex([100,0,0],[50,50,0],2);
  s=await state();dist=Math.hypot(...s.points[0].point.map((x,i)=>x-s.points[1].point[i]));
  if(s.unit!=='mm'||!s.points.every(p=>p.snapped)||Math.abs(dist-100)>.001)throw Error('3DM distance or units wrong '+JSON.stringify(s));
  console.log('PASS Android native 3DM 100 mm edge and units');
  await page.locator('.o3dv-measure-close').click();
 } else console.log('SKIP Android 3DM: native cache fixture not generated');
 if(fs.existsSync('build/ios/memory-stream-tests/fixtures/measure-work/expected.json')) {
  const expected=JSON.parse(fs.readFileSync('build/ios/memory-stream-tests/fixtures/measure-work/expected.json','utf8'));
  await page.evaluate(()=>{window.events=[];window.O3DVOpenStream(location.origin+'/models/measure-work/manifest.json');});
  await page.waitForFunction(()=>window.events.some(e=>e.type==='model_loaded'||e.type==='javascript_error'),null,{timeout:40000});
  const failure=await page.evaluate(()=>window.events.find(e=>e.type==='javascript_error'));if(failure)throw Error(JSON.stringify(failure));
  await page.locator('.o3dv-measure-toggle').click();
  const center=expected.points[0].map((v,i)=>(v+expected.points[1][i])/2);
  await clickVertex(expected.points[0],center,1,false);await clickVertex(expected.points[1],center,2,false);
  s=await state();dist=Math.hypot(...s.points[0].point.map((x,i)=>x-s.points[1].point[i]));
  if(s.unit!=='mm'||!s.points.every((p,i)=>p.snapped&&Math.hypot(...p.point.map((v,j)=>v-expected.points[i][j]))<expected.tolerance)||Math.abs(dist-expected.distance)>expected.tolerance)throw Error('Work 3DM source coordinate mismatch '+JSON.stringify(s));
  console.log('PASS real work 3DM line endpoints and distance against source');
  await page.locator('.o3dv-measure-close').click();
 } else console.log('SKIP real work 3DM: local fixture not generated');
 await page.evaluate(()=>{window.events=[];window.O3DVOpenFiles([location.origin+'/measure-quad.stl']);});
 await page.waitForFunction(()=>window.events.some(e=>e.type==='model_loaded'||e.type==='javascript_error'),null,{timeout:40000});
 const normalError=await page.evaluate(()=>window.events.find(e=>e.type==='javascript_error'));if(normalError)throw Error(JSON.stringify(normalError));
 await page.locator('.o3dv-measure-toggle').click();await clickVertex([20,0,-20],[50,0,-50],1,false);await clickVertex([80,0,-20],[50,0,-50],2,false);
 s=await state();dist=Math.hypot(...s.points[0].point.map((x,i)=>x-s.points[1].point[i]));
 if(!s.points.every(p=>!p.snapped)||dist<50||dist>70||s.unit)throw Error('Wrong ordinary STL measurement '+JSON.stringify(s));
 console.log('PASS ordinary imported STL measurement and unknown units');
 for (const ext of ['obj','fbx','glb']) {
  const fixture='build/android-tests/measurement-formats/size100.'+ext;
  if(!fs.existsSync(fixture)){console.log('SKIP '+ext+': Blender fixture not generated');continue;}
  fs.copyFileSync(fixture,'build/ios/WebAssets/measure-quad.'+ext);
  await page.evaluate(ext=>{window.events=[];window.O3DVOpenFiles([location.origin+'/measure-quad.'+ext]);},ext);
  await page.waitForFunction(()=>window.events.some(e=>['model_loaded','javascript_error','import_failed','failed_to_load_file'].includes(e.type)),null,{timeout:40000});
  const failure=await page.evaluate(()=>window.events.find(e=>['javascript_error','import_failed','failed_to_load_file'].includes(e.type)));if(failure)throw Error(ext+': '+JSON.stringify(failure));
  const bounds=await page.evaluate(()=>window.O3DVMeasurementBounds());
  const expected=ext==='fbx'?10000:100;
  const spans=[0,1,2].map(i=>bounds[i+3]-bounds[i]);const axis=spans.findIndex(v=>Math.abs(v-expected)<.01);
  if(axis<0)throw Error(ext+': dimensions altered '+bounds);
  const other=spans.findIndex((v,i)=>i!==axis&&Math.abs(v-expected)<.01);if(other<0)throw Error(ext+': second dimension altered '+bounds);
  const a=bounds.slice(0,3),b=a.slice(),center=a.slice();b[axis]=bounds[axis+3];center[axis]=(a[axis]+b[axis])/2;center[other]=(bounds[other]+bounds[other+3])/2;
  await page.locator('.o3dv-measure-toggle').click();await clickVertex(a,center,1);await clickVertex(b,center,2);s=await state();dist=Math.hypot(...s.points[0].point.map((x,i)=>x-s.points[1].point[i]));
  if(!s.points.every(p=>p.snapped)||Math.abs(dist-expected)>.01)throw Error(ext+': wrong distance '+JSON.stringify(s));
  if(ext==='fbx'&&s.unit!=='cm')throw Error('FBX unit not recognized: '+JSON.stringify(s));
  console.log('PASS '+ext+' imported known-size edge and vertex snapping');
 }
 if(errors.length)throw Error(errors.join('\n'));await browser.close();
})().catch(e=>{console.error(e);process.exitCode=1}).finally(()=>{
 for(const ext of ['stl','obj','fbx','glb'])fs.rmSync('build/ios/WebAssets/measure-quad.'+ext,{force:true});
});
