const fs=require('fs');const {chromium}=require(process.env.O3DV_PLAYWRIGHT_MODULE||'playwright');
(async()=>{
 const base=fs.readFileSync('build/ios/gltf-stream-tests/server-url.txt','utf8');
 const rows=JSON.parse(fs.readFileSync('build/ios/draco-stream-tests/native-results.json')).cases;
 const browser=await chromium.launch({...(process.env.O3DV_BROWSER_EXECUTABLE?{executablePath:process.env.O3DV_BROWSER_EXECUTABLE}:{}),headless:true,args:['--use-angle=swiftshader','--enable-webgl','--ignore-gpu-blocklist']});
 const page=await browser.newPage({viewport:{width:640,height:700}});const errors=[];page.on('pageerror',e=>errors.push(String(e)));
 await page.route(/\/o3dv\/o3dv\.website\.min\.js(?:\?.*)?$/,r=>r.fulfill({contentType:'application/javascript',body:fs.readFileSync('build/ios/gltf-stream-tests/gltf-test.min.js')}));
 await page.addInitScript(()=>{window.O3DVNativeDebug=true;window.events=[];window.webkit={messageHandlers:{o3dv:{postMessage:m=>window.events.push(m)}}};});
 await page.goto(base);await page.waitForFunction(()=>window.gltfTest&&window.O3DVOpenStream);
 await page.addScriptTag({url:base+'imports/build/ios/gltf-stream-tests/gltf-reference.js'});
 async function pixels(){return page.evaluate(async()=>{const b=await createImageBitmap(await(await fetch(O3DVGetThumbnail())).blob());const c=document.createElement('canvas');c.width=b.width;c.height=b.height;c.getContext('2d').drawImage(b,0,0);return Array.from(c.getContext('2d').getImageData(0,0,c.width,c.height).data);});}
 function diff(a,b){let mismatch=0,total=0;for(let i=0;i<a.length;i++){const d=Math.abs(a[i]-b[i]);if(d>2)mismatch++;total+=d;}return{mismatch,meanAbsoluteError:total/a.length};}
 const results=[];
 for(const row of rows){
  const states=[],frames=[];const low=row.name==='large'?8*1048576:262144;
  for(const budget of [256*1048576,low]){
   await page.evaluate(({cache,budget})=>{window.events=[];O3DVSetMemoryPolicy({geometryBytes:budget,textureBytes:24*1048576,framePixels:1000000});O3DVOpenStream(location.origin+'/imports/'+cache+'/manifest.json');gltfTest.website.viewer.SetBackgroundColor({r:40,g:40,b:40,a:255});},{cache:row.cache,budget});
   await page.waitForFunction(()=>events.some(m=>['model_loaded','javascript_error'].includes(m.type)),null,{timeout:120000});
   const state=await page.evaluate(()=>events.find(m=>['model_loaded','javascript_error'].includes(m.type)));
   if(state.type!=='model_loaded'||state.peakWorkingBytes>budget)throw Error(JSON.stringify(state));
   if(state.dracoDecodedPrimitiveCount!==row.decodedPrimitives||state.triangles!==row.triangles)throw Error('Draco scene count mismatch');
   await page.waitForTimeout(150);states.push(state);frames.push(await pixels());
  }
  const paged=diff(frames[0],frames[1]);if(paged.mismatch>20)throw Error(row.name+' budget changed final pixels '+JSON.stringify(paged));
  const ref=await page.evaluate(async(file)=>{const {stream,website}=gltfTest,viewer=website.viewer,pager=stream.pager;const reference=await gltfReference(location.origin+'/imports/'+file);const previous=stream.root.children;stream.root.children=[reference];reference.parent=stream.root;
   viewer.renderer.setRenderTarget(pager.target);viewer.renderer.clear(true,true,true);viewer.renderer.render(viewer.scene,viewer.camera);viewer.renderer.setRenderTarget(null);const data=pager.Thumbnail();stream.root.children=previous;
   const b=await createImageBitmap(await(await fetch(data)).blob());const c=document.createElement('canvas');c.width=b.width;c.height=b.height;c.getContext('2d').drawImage(b,0,0);
   reference.traverse(o=>{o.geometry?.dispose();if(o.material)for(const m of Array.isArray(o.material)?o.material:[o.material])m.dispose();});return Array.from(c.getContext('2d').getImageData(0,0,c.width,c.height).data);},row.reference);
  const independent=diff(frames[1],ref);if(independent.meanAbsoluteError>1.5)throw Error(row.name+' independent frame differs '+JSON.stringify(independent));
  await page.screenshot({path:'build/ios/draco-stream-tests/'+row.name+'-browser.png'});
  results.push({name:row.name,states,paged,independent});console.log('PASS',row.name,'paged',paged.mismatch,'independent',independent);
 }
 if(errors.length)throw Error(errors.join('\n'));fs.writeFileSync('build/ios/draco-stream-tests/browser-results.json',JSON.stringify({passed:true,results,errors},null,2));await browser.close();
})().catch(e=>{console.error(e);process.exit(1)});
