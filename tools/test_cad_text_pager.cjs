const fs=require('fs');
const {chromium}=require(process.env.O3DV_PLAYWRIGHT_MODULE||'playwright');
(async()=>{
 const root='build/ios/cad-text-tests/';const base=fs.readFileSync('build/ios/gltf-stream-tests/server-url.txt','utf8').trim();
 const browser=await chromium.launch({headless:true,args:['--use-angle=swiftshader','--enable-webgl','--ignore-gpu-blocklist']});const page=await browser.newPage({viewport:{width:800,height:650}});const errors=[];page.on('pageerror',e=>errors.push(String(e)));
 await page.route(/\/o3dv\/o3dv\.website\.min\.js(?:\?.*)?$/,r=>r.fulfill({contentType:'application/javascript',body:fs.readFileSync('build/ios/gltf-stream-tests/gltf-test.min.js')}));
 await page.addInitScript(()=>{window.O3DVNativeDebug=true;window.events=[];window.webkit={messageHandlers:{o3dv:{postMessage:m=>window.events.push(m)}}};});
 await page.goto(base);await page.waitForFunction(()=>window.gltfTest&&window.O3DVOpenStream);const results=[];
 for(const name of ['mtext','attributes','saved-dimension','generated-normal','chinese-hole','transformed','mtext-wide','wrap-wide','underline-range','chinese-overlap','work-4']){
  const frames=[],states=[];
  for(const budget of [64*1048576,262144]){
   await page.evaluate(({name,budget,root})=>{window.events=[];O3DVSetMemoryPolicy({geometryBytes:budget,textureBytes:1048576,framePixels:1000000});O3DVOpenStream(location.origin+'/imports/'+root+'caches/'+name+'/manifest.json');},{name,budget,root});
   await page.waitForFunction(()=>events.some(e=>['model_loaded','javascript_error'].includes(e.type)),null,{timeout:240000});
   const state=await page.evaluate(()=>events.find(e=>['model_loaded','javascript_error'].includes(e.type)));if(state.type!=='model_loaded'||state.peakWorkingBytes>state.peakWorkingBudgetBytes||state.residentPeakBytes>budget)throw Error(JSON.stringify(state));
   const pixels=await page.evaluate(async()=>{const im=await createImageBitmap(await(await fetch(O3DVGetThumbnail())).blob());const c=document.createElement('canvas');c.width=im.width;c.height=im.height;c.getContext('2d').drawImage(im,0,0);return Array.from(c.getContext('2d').getImageData(0,0,c.width,c.height).data);});frames.push(pixels);states.push(state);
  }
  let mismatch=0;for(let i=0;i<frames[0].length;i++)if(Math.abs(frames[0][i]-frames[1][i])>2)mismatch++;if(mismatch>40)throw Error(name+' paging changed glyph pixels '+mismatch);
  await page.screenshot({path:root+'browser-'+name+'.png'});results.push({name,states,mismatch});console.log('PASS',name,states[0].textObjects,states[0].triangles,mismatch);
 }
 if(errors.length)throw Error(errors.join('\n'));fs.writeFileSync(root+'browser-results.json',JSON.stringify({passed:true,results,errors},null,2));await browser.close();
})().catch(e=>{console.error(e);process.exit(1)});
