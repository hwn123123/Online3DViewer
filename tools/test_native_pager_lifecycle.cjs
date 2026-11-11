// Exercise budget changes and lifecycle using generated, format-independent geometry.
const {chromium}=require(process.env.O3DV_PLAYWRIGHT_MODULE || 'playwright');
const fs=require('fs');
const root='build/ios/memory-stream-tests/fixtures';
(async()=>{
 const browser=await chromium.launch({...(process.env.O3DV_BROWSER_EXECUTABLE?{executablePath:process.env.O3DV_BROWSER_EXECUTABLE}:{}),headless:true,args:['--use-angle=swiftshader','--enable-webgl','--ignore-gpu-blocklist']});
 const page=await browser.newPage({viewport:{width:600,height:650}});const errors=[];page.on('pageerror',e=>errors.push(String(e)));
 await page.addInitScript(()=>{window.events=[];window.webkit={messageHandlers:{o3dv:{postMessage:m=>window.events.push(m)}}};});
 await page.goto('http://127.0.0.1:8097/');await page.waitForFunction(()=>typeof window.O3DVOpenStream==='function');
 async function wait(type,complete=false){await page.waitForFunction(({type,complete})=>window.events.some(m=>m.type==='javascript_error'||(m.type===type&&(!complete||m.complete))),{type,complete},{timeout:30000});const state=await page.evaluate(({type,complete})=>window.events.find(m=>m.type==='javascript_error'||(m.type===type&&(!complete||m.complete))),{type,complete});if(state.type==='javascript_error')throw Error(JSON.stringify(state));return state;}
 async function open(name,budget=262144){await page.evaluate(({name,budget})=>{window.events=[];window.O3DVSetMemoryPolicy({geometryBytes:budget,textureBytes:1048576,framePixels:1000000});window.O3DVOpenStream(location.origin+'/models/'+name+'/manifest.json');},{name,budget});return await wait('model_loaded');}
 async function pixels(){return await page.evaluate(async()=>{const response=await fetch(window.O3DVGetThumbnail());const bitmap=await createImageBitmap(await response.blob());const c=document.createElement('canvas');c.width=bitmap.width;c.height=bitmap.height;c.getContext('2d').drawImage(bitmap,0,0);return Array.from(c.getContext('2d').getImageData(0,0,c.width,c.height).data);});}
 function equal(a,b){if(a.length!==b.length)throw Error('image size changed');let mismatch=0;for(let i=0;i<a.length;i++)if(Math.abs(a[i]-b[i])>2)mismatch++;if(mismatch>20)throw Error('Complete frame lost geometry: '+mismatch+' pixels differ');}
 await open('opaque');const expected=await pixels();
 for(const budget of [524288,262144]){
  await page.evaluate(budget=>{window.events=[];window.O3DVSetMemoryPolicy({geometryBytes:budget,textureBytes:1048576,framePixels:1000000});},budget);const state=await wait('stream_view_progress',true);if(state.residentBytes>budget)throw Error('Residency exceeds changed budget');equal(expected,await pixels());
 }
 console.log('PASS budget changes preserve the complete frame');
 await page.evaluate(()=>window.events=[]);await page.locator('#viewer').click();const selected=await wait('stream_selection');if(selected.object.id!=='plane-2')throw Error('Wrong front object');await wait('stream_view_progress',true);equal(expected,await pixels());
 for(const visible of [false,true]){await page.evaluate(visible=>{window.events=[];window.O3DVSetStreamLayers({'0':visible});},visible);await wait('stream_view_progress',true);}
 equal(expected,await pixels());console.log('PASS evicted object picking and visibility redraw');
 await page.evaluate(()=>{window.O3DVSetForeground(false);window.events=[];window.O3DVOpenStream(location.origin+'/models/transparent/manifest.json');});
 await page.waitForTimeout(450);if(await page.evaluate(()=>window.events.some(e=>e.type==='model_loaded')))throw Error('Rendered while suspended');
 await page.evaluate(()=>window.O3DVSetForeground(true));await wait('model_loaded');console.log('PASS foreground resumes a suspended incomplete frame');
 await open('opaque');await page.evaluate(()=>{window.events=[];const c=document.getElementById('viewer');const gl=c.getContext('webgl2')||c.getContext('webgl');window.contextLoss=gl.getExtension('WEBGL_lose_context');window.contextLoss.loseContext();});
 await wait('stream_render_paused');await page.waitForTimeout(100);await page.evaluate(()=>window.contextLoss.restoreContext());await wait('stream_view_progress',true);await page.screenshot({path:'build/ios/memory-stream-tests/context-restored.png'});equal(expected,await pixels());console.log('PASS GPU context recovery rebuilds the complete frame');
 await page.evaluate(()=>{window.events=[];window.O3DVOpenStream(location.origin+'/models/transparent/manifest.json');window.O3DVOpenStream(location.origin+'/models/opaque/manifest.json');});const latest=await wait('model_loaded');if(latest.name!=='opaque')throw Error('Stale model completed');equal(expected,await pixels());console.log('PASS rapid replacement cancels old geometry work');
 const partial=root+'/partial';fs.mkdirSync(partial,{recursive:true});const full=JSON.parse(fs.readFileSync(root+'/opaque/manifest.json'));
 for(const o of full.objects)fs.copyFileSync(root+'/opaque/'+o.url,partial+'/'+o.url);
 const manifest={...full,complete:false,objects:full.objects.slice(0,1),objectCount:1};fs.writeFileSync(partial+'/manifest.json',JSON.stringify(manifest));
 await page.evaluate(()=>{window.events=[];window.O3DVOpenStream(location.origin+'/models/partial/manifest.json');});await wait('stream_progress');if(await page.evaluate(()=>window.events.some(e=>e.type==='model_loaded')))throw Error('Partial manifest reported success');
 fs.writeFileSync(partial+'/manifest.json',JSON.stringify(full));await wait('model_loaded');equal(expected,await pixels());console.log('PASS incremental manifests include all later geometry');
 await open('texture');await page.screenshot({path:'build/ios/memory-stream-tests/texture-lifecycle.png'});await open('legacy');console.log('PASS bounded texture and v1 cache compatibility');
 await page.evaluate(()=>window.events=[]);const canvas=page.locator('#viewer');const box=await canvas.boundingBox();await page.mouse.move(box.x+box.width*.5,box.y+box.height*.5);await page.mouse.down();await page.mouse.move(box.x+box.width*.8,box.y+box.height*.7,{steps:6});await page.mouse.up();await wait('stream_view_progress',true);console.log('PASS rotation rebuilds paged geometry');
 if(errors.length)throw Error(errors.join('\n'));await browser.close();console.log('PASS lifecycle checks');
})().catch(e=>{console.error(e);process.exit(1)});
