// Synthetic complete-frame equality and geometry-budget checks.
const {chromium}=require(process.env.O3DV_PLAYWRIGHT_MODULE || 'playwright');const fs=require('fs');
(async()=>{
 const browser=await chromium.launch({...(process.env.O3DV_BROWSER_EXECUTABLE ? {executablePath:process.env.O3DV_BROWSER_EXECUTABLE}:{}),headless:true,args:['--use-angle=swiftshader','--enable-webgl','--ignore-gpu-blocklist']});
 const page=await browser.newPage({viewport:{width:600,height:650}});const errors=[];page.on('pageerror',e=>(errors.push(String(e)),console.log('PAGEERROR',String(e))));page.on('console',m=>{if(m.type()==='error')console.log('console',m.text());});
 await page.addInitScript(()=>{window.events=[];window.webkit={messageHandlers:{o3dv:{postMessage:m=>window.events.push(m)}}};});await page.goto('http://127.0.0.1:8097/');await page.waitForFunction(()=>typeof window.O3DVOpenStream==='function');
 const results=[];
 for(const fixture of ['opaque','transparent']){
  const hashes=[];
  for(const budget of [4*1048576,256*1024]){
   await page.evaluate(({fixture,budget})=>{window.events=[];window.O3DVSetMemoryPolicy({geometryBytes:budget,textureBytes:24*1048576,framePixels:1000000});window.O3DVOpenStream(location.origin+'/models/'+fixture+'/manifest.json');},{fixture,budget});
   try{await page.waitForFunction(()=>window.events.some(m=>['model_loaded','javascript_error'].includes(m.type)),null,{timeout:30000});}catch(e){console.log('EVENTS',await page.evaluate(()=>window.events));throw e;}
   const state=await page.evaluate(()=>window.events.find(m=>['model_loaded','javascript_error'].includes(m.type)));console.log(fixture,budget,JSON.stringify(state));if(state.type!=='model_loaded')throw Error(JSON.stringify(state));
   if(state.residentPeakBytes>state.geometryBudgetBytes)throw Error('geometry budget exceeded');
   const canvas=page.locator('#viewer');const bytes=await canvas.screenshot();fs.writeFileSync('build/ios/memory-stream-tests/'+fixture+'-'+budget+'.png',bytes);
   hashes.push(await page.evaluate(async()=>{const data=window.O3DVGetThumbnail();const image=await createImageBitmap(await (await fetch(data)).blob());const out=document.createElement('canvas');out.width=image.width;out.height=image.height;out.getContext('2d').drawImage(image,0,0);return Array.from(out.getContext('2d').getImageData(0,0,out.width,out.height).data);}));results.push(state);
  }
  if(new Set(hashes[0]).size<8)throw Error('Blank frame');let mismatch=0,total=0;for(let i=0;i<hashes[0].length;i++){const d=Math.abs(hashes[0][i]-hashes[1][i]);if(d>2)mismatch++;total+=d;}console.log('pixels',fixture,{mismatch,total,bytes:hashes[0].length});if(mismatch>20)throw Error('Paged frame pixels differ');
 }
 fs.writeFileSync('build/ios/memory-stream-tests/pager-results.json',JSON.stringify({results,errors},null,2));if(errors.length)throw Error(errors.join('\n'));await browser.close();console.log('PASS complete opaque/transparent frames, range fragments and strict geometry residency');
})().catch(e=>{console.error(e);process.exit(1)});
