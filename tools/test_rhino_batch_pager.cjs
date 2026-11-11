// Compare complete views before/after batching and preserve the prior view during slow redraws.
const {chromium} = require(process.env.O3DV_PLAYWRIGHT_MODULE || 'playwright');
const fs = require('fs');
(async () => {
 const browser = await chromium.launch({headless:true,args:['--use-angle=swiftshader','--enable-webgl','--ignore-gpu-blocklist']});
 const page = await browser.newPage({viewport:{width:600,height:650}}); const errors=[];
 page.on('pageerror', e => errors.push(String(e)));
 await page.addInitScript(() => {
  window.events=[]; window.delayReads=0; window.O3DVNativeDebug=true;
  window.webkit={messageHandlers:{o3dv:{postMessage:m=>window.events.push(m)}}};
  const original=window.fetch;
  window.fetch=async (...args) => {
   if(String(args[0]).includes('.bin') && window.delayReads) {
    const signal=args[1]?.signal;
    await new Promise((resolve,reject)=>{const timer=setTimeout(resolve,window.delayReads);signal?.addEventListener('abort',()=>{clearTimeout(timer);reject(new DOMException('Aborted','AbortError'));},{once:true});});
   }
   return original(...args);
  };
 });
 await page.goto('http://127.0.0.1:8097/');await page.waitForFunction(()=>window.O3DVOpenStream);
 const wait = async (predicate) => {
  await page.waitForFunction(p => events.some(e=>e.type==='javascript_error'||(e.type===p.type&&e.complete===p.complete)),predicate,{timeout:120000});
  const result=await page.evaluate(p=>events.find(e=>e.type==='javascript_error'||(e.type===p.type&&e.complete===p.complete)),predicate);
  if(result.type==='javascript_error')throw Error(JSON.stringify(result));return result;
 };
 const pixels = () => page.evaluate(async()=>{const url=window.O3DVGetThumbnail();if(!url)throw Error('Missing complete image');const im=await createImageBitmap(await(await fetch(url)).blob());const c=document.createElement('canvas');c.width=im.width;c.height=im.height;c.getContext('2d').drawImage(im,0,0);return Array.from(c.getContext('2d').getImageData(0,0,c.width,c.height).data);});
 const diff = (a,b) => {let n=0;for(let i=0;i<a.length;i++)if(Math.abs(a[i]-b[i])>2)n++;return n;};
 const open = async name => {await page.evaluate(name=>{window.events=[];window.delayReads=0;O3DVSetMemoryPolicy({geometryBytes:4*1048576,textureBytes:1048576,framePixels:1000000});O3DVOpenStream(location.origin+'/models/'+name+'/manifest.json');},name);return await wait({type:'model_loaded',complete:true});};
 const original=await open('rhino-batch-before');const baseline=await pixels();
 if(new Set(baseline).size<8)throw Error('The source model frame is blank');
 await page.evaluate(()=>{window.events=[];window.delayReads=20;window.navPromise=O3DVBenchmarkNavigation().catch(()=>null);});
 const partial=await wait({type:'stream_view_progress',complete:false});const held=await pixels();
 const partialDiff=diff(baseline,held);if(partialDiff>20)throw Error('Previous complete view changed during partial redraw: '+partialDiff);
 await page.evaluate(()=>{window.delayReads=0;O3DVStop();});
 const optimized=await open('rhino-batch-after');const after=await pixels();const imageDiff=diff(baseline,after);
 // Rebasing float vertices can move antialiased edge pixels by a fraction of a pixel.
 if(imageDiff>100)throw Error('Batching changed the final image: '+imageDiff);
 if(optimized.objectCount>=original.objectCount)throw Error('Batching did not reduce display objects');
 if(errors.length)throw Error(errors.join('\n'));
 fs.writeFileSync('build/ios/navigation-refresh-fix/browser-batch-results.json',JSON.stringify({original,optimized,partial,partialDiff,imageDiff},null,2));
 await browser.close();console.log('PASS complete frame preserved during slow navigation; batched and original images agree',partialDiff,imageDiff);
})().catch(e=>{console.error(e);process.exit(1)});
