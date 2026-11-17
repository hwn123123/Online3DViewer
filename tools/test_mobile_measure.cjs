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
(async()=>{
 const browser=await chromium.launch({...(process.env.O3DV_BROWSER_EXECUTABLE?{executablePath:process.env.O3DV_BROWSER_EXECUTABLE}:{}),headless:true,args:['--use-angle=swiftshader','--enable-webgl','--ignore-gpu-blocklist']});
 const page=await browser.newPage({viewport:{width:600,height:700}});const errors=[];page.on('pageerror',e=>errors.push(String(e)));
 await page.addInitScript(()=>{window.O3DVNativeDebug=true;window.events=[];window.webkit={messageHandlers:{o3dv:{postMessage:m=>window.events.push(m)}}};});
 await page.goto('http://127.0.0.1:8097/');await page.waitForFunction(()=>window.O3DVOpenStream);
 async function open(file){await page.evaluate(file=>{window.events=[];window.O3DVOpenStream(location.origin+'/models/measure-test/'+file);},file);await page.waitForFunction(()=>window.events.some(e=>e.type==='model_loaded'||e.type==='javascript_error'),null,{timeout:40000});const err=await page.evaluate(()=>window.events.find(e=>e.type==='javascript_error'));if(err)throw Error(JSON.stringify(err));await page.locator('.o3dv-measure-toggle').click();}
 async function clickVertex(point,center,count){const [v,c]=await page.evaluate(([a,b])=>[window.O3DVProjectMeasurementPoint(a),window.O3DVProjectMeasurementPoint(b)],[point,center]);const canvas=await page.locator('#viewer').boundingBox();const dx=c[0]-v[0],dy=c[1]-v[1],d=Math.hypot(dx,dy);await page.mouse.click(canvas.x+v[0]+dx/d*5,canvas.y+v[1]+dy/d*5);try { await page.waitForFunction(n=>window.O3DVMeasurementDebug().points.length===n,count,{timeout:5000}); } catch (e) { console.log('pick failure', point, v, c, canvas, await page.evaluate(([x,y])=>{const e=document.elementFromPoint(x,y);return e?.outerHTML?.slice(0,250)},[canvas.x+v[0]+dx/d*5,canvas.y+v[1]+dy/d*5]), await page.locator('.o3dv-measure-result').textContent(), await page.evaluate(()=>window.O3DVMeasurementDebug())); throw e; }}
 async function state(){return page.evaluate(()=>window.O3DVMeasurementDebug());}
 await open('manifest.json');await clickVertex([0,0,0],[50,50,0],1);await clickVertex([100,0,0],[50,50,0],2);
 let s=await state();let dist=Math.hypot(...s.points[0].point.map((x,i)=>x-s.points[1].point[i]));if(!s.points.every(p=>p.snapped)||Math.abs(dist-100)>1e-5)throw Error('Incorrect vertex distance '+JSON.stringify(s));
 if(!(await page.locator('.o3dv-measure-result').textContent()).includes('单位未知'))throw Error('Unknown units were silently assigned');
 await page.locator('.o3dv-measure-controls select').selectOption('mm');if(!(await page.locator('.o3dv-measure-result').textContent()).includes('100 mm'))throw Error('Unit label wrong');
 console.log('PASS known 100-unit edge, vertex snapping and unknown-unit confirmation');
 await page.locator('.o3dv-measure-clear').click();if((await state()).points.length)throw Error('Clear failed');
 await open('transformed.json');if((await state()).unit!=='mm')throw Error('File units not applied');await clickVertex([1000,2000,3],[1125,2050,3],1);await clickVertex([1200,2000,3],[1125,2050,3],2);s=await state();dist=Math.hypot(...s.points[0].point.map((x,i)=>x-s.points[1].point[i]));if(!s.points.every(p=>p.snapped)||Math.abs(dist-200)>1e-5)throw Error('Incorrect transformed measurement '+JSON.stringify(s));
 console.log('PASS transformed instance world coordinates and recognized units');
 await page.locator('.o3dv-measure-close').click();if((await state()).active||(await state()).points.length)throw Error('Close failed');
 await page.evaluate(()=>{window.events=[];window.O3DVOpenFiles([location.origin+'/measure-quad.stl']);});
 await page.waitForFunction(()=>window.events.some(e=>e.type==='model_loaded'||e.type==='javascript_error'),null,{timeout:40000});
 const normalError=await page.evaluate(()=>window.events.find(e=>e.type==='javascript_error'));if(normalError)throw Error(JSON.stringify(normalError));
 await page.locator('.o3dv-measure-toggle').click();await clickVertex([20,0,-20],[50,0,-50],1);await clickVertex([80,0,-20],[50,0,-50],2);
 s=await state();dist=Math.hypot(...s.points[0].point.map((x,i)=>x-s.points[1].point[i]));
 if(!s.points.every(p=>!p.snapped)||dist<50||dist>70||s.unit)throw Error('Wrong ordinary STL measurement '+JSON.stringify(s));
 console.log('PASS ordinary imported STL measurement and unknown units');
 if(errors.length)throw Error(errors.join('\n'));await browser.close();
})().catch(e=>{console.error(e);process.exit(1)});
