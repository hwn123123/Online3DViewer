// Check STL cache integration: whole/range display, complete pixels, and logical mesh picking.
const {chromium}=require(process.env.O3DV_PLAYWRIGHT_MODULE || 'playwright');
const fs=require('fs');
(async()=>{
 const browser=await chromium.launch({...(process.env.O3DV_BROWSER_EXECUTABLE?{executablePath:process.env.O3DV_BROWSER_EXECUTABLE}:{}),headless:true,args:['--use-angle=swiftshader','--enable-webgl','--ignore-gpu-blocklist']});
 const page=await browser.newPage({viewport:{width:640,height:700}});const errors=[];
 page.on('pageerror',e=>errors.push(String(e)));
 await page.addInitScript(()=>{window.O3DVNativeDebug=true;window.events=[];window.webkit={messageHandlers:{o3dv:{postMessage:m=>window.events.push(m)}}};});
 await page.goto('http://127.0.0.1:8097/');await page.waitForFunction(()=>typeof window.O3DVOpenStream==='function');
 const results=[];
 for(const name of ['stl-utah_teapot','stl-cube_meshlab_ascii','stl-chunk-boundaries']){
  let reference=null;
  for(const budget of [8*1048576,262144]){
   await page.evaluate(({name,budget})=>{window.events=[];window.O3DVSetMemoryPolicy({geometryBytes:budget,textureBytes:1048576,framePixels:1000000});window.O3DVOpenStream(location.origin+'/models/'+name+'/manifest.json');},{name,budget});
   await page.waitForFunction(()=>window.events.some(m=>['model_loaded','javascript_error'].includes(m.type)),null,{timeout:90000});
   const state=await page.evaluate(()=>window.events.find(m=>['model_loaded','javascript_error'].includes(m.type)));
   if(state.type!=='model_loaded'||state.reader!=='stl-stream-1'||!state.complete||state.displayed!==state.objectCount)throw Error(JSON.stringify(state));
   if(state.peakWorkingBytes>budget)throw Error('geometry and prefetch exceeded budget');
   const pixels=await page.evaluate(async()=>{const b=await createImageBitmap(await(await fetch(window.O3DVGetThumbnail())).blob());const c=document.createElement('canvas');c.width=b.width;c.height=b.height;c.getContext('2d').drawImage(b,0,0);return Array.from(c.getContext('2d').getImageData(0,0,c.width,c.height).data);});
   if(new Set(pixels).size<8)throw Error('Blank STL frame');let mismatch=0;
   if(reference){for(let i=0;i<pixels.length;i++)if(Math.abs(pixels[i]-reference[i])>2)mismatch++;if(mismatch>20)throw Error('STL paged pixels differ: '+mismatch);}
   else reference=pixels;
   results.push({name,budget,pixelMismatch:mismatch,state});
   await page.screenshot({path:'build/ios/stl-stream-tests/'+name+'-'+budget+'.png'});
   console.log('PASS',name,budget,'faces',state.triangles,'pixelMismatch',mismatch);
  }
  if(name==='stl-cube_meshlab_ascii'){
   await page.evaluate(()=>window.events=[]);await page.locator('#viewer').click();
   await page.waitForFunction(()=>window.events.some(m=>m.type==='stream_selection'),null,{timeout:10000});
   const picked=await page.evaluate(()=>window.events.find(m=>m.type==='stream_selection'));
   if(picked.object.id!=='stl-solid-0')throw Error('STL picking lost the source mesh identity: '+JSON.stringify(picked));
  }
  // A same-camera resize during a slow fragmented frame must not strand the benchmark on an old serial.
  if(name==='stl-utah_teapot'){
   const frames=await page.evaluate(async()=>{
    const navigation=window.O3DVBenchmarkNavigation();
    setTimeout(()=>window.dispatchEvent(new Event('resize')),5);
    return Promise.race([navigation,new Promise((_,reject)=>setTimeout(()=>reject(Error('Benchmark stalled after resize')),15000))]);
   });
   if(frames.length!==3||frames.some(f=>!f.gpuComplete))throw Error('Incomplete navigation after resize');
   console.log('PASS navigation benchmark survives a same-camera resize');
  }
 }
 if(errors.length)throw Error(errors.join('\n'));
 fs.writeFileSync('build/ios/stl-stream-tests/browser-results.json',JSON.stringify({passed:true,results,errors},null,2));await browser.close();
})().catch(e=>{console.error(e);process.exit(1)});
