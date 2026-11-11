// Identical camera work before/after optimization, with full-frame fingerprints.
const {chromium}=require(process.env.O3DV_PLAYWRIGHT_MODULE || 'playwright');const fs=require('fs');
(async()=>{
 const stage=process.argv[2]||'baseline';const out='build/ios/render-performance-tests/'+stage;fs.mkdirSync(out,{recursive:true});
 const browser=await chromium.launch({...(process.env.O3DV_BROWSER_EXECUTABLE?{executablePath:process.env.O3DV_BROWSER_EXECUTABLE}:{}),headless:true,args:['--use-angle=swiftshader','--enable-webgl','--ignore-gpu-blocklist']});const page=await browser.newPage({viewport:{width:640,height:700}});const errors=[];page.on('pageerror',e=>errors.push(String(e)));
 await page.addInitScript(()=>{window.O3DVNativeDebug=true;window.events=[];window.webkit={messageHandlers:{o3dv:{postMessage:m=>window.events.push(m)}}};});await page.goto('http://127.0.0.1:8097/');await page.waitForFunction(()=>typeof window.O3DVBenchmarkNavigation==='function');
 const results=[];
 for(const [name,budget] of [['many-instances',2*1048576],['distinct-blocks',1048576],['legacy-blocks',1048576]]){
  await page.evaluate(({name,budget})=>{window.events=[];window.O3DVSetMemoryPolicy({geometryBytes:budget,textureBytes:24*1048576,framePixels:3500000});window.O3DVOpenStream(location.origin+'/models/'+name+'/manifest.json');},{name,budget});
  await page.waitForFunction(()=>window.events.some(m=>['model_loaded','javascript_error'].includes(m.type)),null,{timeout:180000});const first=await page.evaluate(()=>window.events.find(m=>['model_loaded','javascript_error'].includes(m.type)));if(first.type==='javascript_error')throw Error(JSON.stringify(first));
  const navigation=await page.evaluate(()=>window.O3DVBenchmarkNavigation());const thumbnail=await page.evaluate(()=>window.O3DVGetThumbnail());const encoded=thumbnail.split(',')[1];fs.writeFileSync(out+'/'+name+'-frame.png',Buffer.from(encoded,'base64'));
  results.push({name,budget,initial:first,navigation});console.log(name,'initial',first.frameElapsedMs,'navigation',navigation.map(m=>m.elapsedMs),'reads',navigation.map(m=>m.frameReadRequests));
 }
 fs.writeFileSync(out+'/browser-benchmarks.json',JSON.stringify({results,errors},null,2));if(errors.length)throw Error(errors.join('\n'));await browser.close();
})().catch(e=>{console.error(e);process.exit(1)});
