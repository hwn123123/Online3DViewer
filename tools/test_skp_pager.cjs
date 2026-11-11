// Exercise SKP textures, component placement and bounded complete frames.
const fs = require('fs');
const {chromium} = require(process.env.O3DV_PLAYWRIGHT_MODULE || 'playwright');
(async () => {
 const stage = process.argv[2] || 'optimized';
 const names = process.argv.slice(3);
 const root = 'build/ios/skp-stream-tests/';
 const base = fs.readFileSync('build/ios/gltf-stream-tests/server-url.txt', 'utf8').trim();
 const bundle = stage === 'baseline' ? root + 'baseline.min.js' : 'build/ios/gltf-stream-tests/gltf-test.min.js';
 const browser = await chromium.launch({headless:true,args:['--use-angle=swiftshader','--enable-webgl','--ignore-gpu-blocklist']});
 const page = await browser.newPage({viewport:{width:430,height:720}});
 const errors=[];page.on('pageerror',e=>errors.push(String(e)));
 await page.route(/\/o3dv\/o3dv\.website\.min\.js(?:\?.*)?$/,r=>r.fulfill({contentType:'application/javascript',body:fs.readFileSync(bundle)}));
 await page.addInitScript(()=>{window.O3DVNativeDebug=true;window.events=[];window.webkit={messageHandlers:{o3dv:{postMessage:m=>window.events.push(m)}}};});
 await page.goto(base);await page.waitForFunction(()=>window.gltfTest&&window.O3DVOpenStream);
 const cases = ['basic','two-sided','instances-lines','visibility','hole'].map(name=>({name,cache:root+'fixture-caches/'+name,budgets:[256*1048576,262144]}));
 cases.push({name:'work-03',cache:root+'caches/03',budgets:[8*1048576]});
 if(names.includes('work-05'))cases.push({name:'work-05',cache:root+'caches/05',budgets:[8*1048576]});
 const results=[];
 for(const row of cases){
  if(names.length&&!names.includes(row.name))continue;
  const frames=[],states=[];
  for(const budget of row.budgets){
   await page.evaluate(({cache,budget})=>{window.events=[];O3DVSetMemoryPolicy({geometryBytes:budget,textureBytes:24*1048576,framePixels:1000000});O3DVOpenStream(location.origin+'/imports/'+cache+'/manifest.json');},{cache:row.cache,budget});
   await page.waitForFunction(()=>events.some(e=>['model_loaded','javascript_error'].includes(e.type)),null,{timeout:240000});
   const state=await page.evaluate(()=>events.find(e=>['model_loaded','javascript_error'].includes(e.type)));
   if(state.type!=='model_loaded'||state.peakWorkingBytes>budget||state.texturePeakBytes>24*1048576)throw Error(JSON.stringify(state));
   const pixels=await page.evaluate(async()=>{const im=await createImageBitmap(await(await fetch(O3DVGetThumbnail())).blob());const c=document.createElement('canvas');c.width=im.width;c.height=im.height;c.getContext('2d').drawImage(im,0,0);return Array.from(c.getContext('2d').getImageData(0,0,c.width,c.height).data);});
   states.push(state);frames.push(pixels);
   console.log('FRAME',stage,row.name,budget,state.frameElapsedMs,'ms',state.frameBatches,'batches');
  }
  let mismatch=0;
  if(frames.length===2){for(let i=0;i<frames[0].length;i++)if(Math.abs(frames[0][i]-frames[1][i])>2)mismatch++;if(mismatch>20)throw Error(row.name+' low budget pixels changed: '+mismatch);}
  fs.writeFileSync(root+stage+'-'+row.name+'-pixels.json',JSON.stringify(frames.at(-1)));
  await page.screenshot({path:root+stage+'-'+row.name+'.png'});
  results.push({name:row.name,states,mismatch});
 }
 if(errors.length)throw Error(errors.join('\n'));
 fs.writeFileSync(root+stage+'-browser-results.json',JSON.stringify({passed:true,results,errors},null,2));
 await browser.close();
})().catch(e=>{console.error(e);process.exit(1)});
