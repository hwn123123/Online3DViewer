const {chromium}=require(process.env.O3DV_PLAYWRIGHT_MODULE || 'playwright');
const fs=require('fs');
(async()=>{
 const base=fs.readFileSync('build/ios/gltf-stream-tests/server-url.txt','utf8');
 const all=JSON.parse(fs.readFileSync('build/ios/gltf-stream-tests/native-results.json')).cases;
 const selected=['BoxTextured/glTF-Binary/BoxTextured.glb','BoxVertexColors/glTF-Binary/BoxVertexColors.glb',
 'OrientationTest/glTF-Binary/OrientationTest.glb','DamagedHelmet/glTF-Binary/DamagedHelmet.glb',
 'CubeHierarchy/CubeHierarchy.gltf','sources/sparse-instances.glb','sources/morph.glb','sources/skin.glb','sources/materials.gltf',
 'Mesh_PrimitiveMode/Mesh_PrimitiveMode_00.gltf','Mesh_PrimitiveMode/Mesh_PrimitiveMode_04.gltf'];
 const browser=await chromium.launch({...(process.env.O3DV_BROWSER_EXECUTABLE?{executablePath:process.env.O3DV_BROWSER_EXECUTABLE}:{}),headless:true,args:['--use-angle=swiftshader','--enable-webgl','--ignore-gpu-blocklist']});
 const page=await browser.newPage({viewport:{width:640,height:700}});const errors=[];page.on('pageerror',e=>errors.push(String(e)));
 await page.route(/\/o3dv\/o3dv\.website\.min\.js(?:\?.*)?$/,route=>route.fulfill({contentType:'application/javascript',body:fs.readFileSync('build/ios/gltf-stream-tests/gltf-test.min.js')}));
 page.on('console',m=>{if(m.type()==='error')console.log('console',m.text());});
 await page.addInitScript(()=>{window.O3DVNativeDebug=true;window.events=[];window.webkit={messageHandlers:{o3dv:{postMessage:m=>window.events.push(m)}}};});
 await page.goto(base);await page.waitForFunction(()=>window.gltfTest&&window.O3DVOpenStream);
 await page.addScriptTag({url:base+'imports/build/ios/gltf-stream-tests/gltf-reference.js'});
 const results=[];
 const wait=async()=>{
  await page.waitForFunction(()=>window.events.some(m=>['model_loaded','javascript_error'].includes(m.type)),null,{timeout:120000});
  const state=await page.evaluate(()=>window.events.find(m=>['model_loaded','javascript_error'].includes(m.type)));
  if(state.type!=='model_loaded')throw Error(JSON.stringify(state));
  return state;
 };
 const pixels=()=>page.evaluate(async()=>{
  const thumbnail=window.O3DVGetThumbnail();const b=await createImageBitmap(await(await fetch(thumbnail)).blob());
  const c=document.createElement('canvas');c.width=b.width;c.height=b.height;c.getContext('2d').drawImage(b,0,0);
  return Array.from(c.getContext('2d').getImageData(0,0,c.width,c.height).data);
 });
 const compare=(a,b)=>{let mismatch=0,sum=0;for(let i=0;i<a.length;i++){const d=Math.abs(a[i]-b[i]);if(d>2)mismatch++;sum+=d;}return {mismatch,meanAbsoluteError:sum/a.length,samples:a.length};};
 for(const suffix of selected){
  const row=all.find(r=>r.status==='passed'&&r.name.endsWith(suffix));if(!row)throw Error('Missing fixture '+suffix);
  const captures=[];const states=[];
  for(const budget of [64*1048576,262144]){
   await page.evaluate(({cache,budget})=>{window.events=[];window.O3DVSetMemoryPolicy({geometryBytes:budget,textureBytes:24*1048576,framePixels:1000000});window.O3DVOpenStream(location.origin+'/imports/'+cache+'/manifest.json');window.gltfTest.website.viewer.SetBackgroundColor({r:40,g:40,b:40,a:255});},{cache:row.cache,budget});
   const state=await wait();if(state.peakWorkingBytes>budget||state.texturePeakBytes>state.textureBudgetBytes)throw Error('Budget exceeded');
   // Wait for the bundled environment map to settle before comparing material shading.
   await page.waitForTimeout(150);captures.push(await pixels());states.push(state);
  }
  const paged=compare(captures[0],captures[1]);
  if(paged.mismatch>20)throw Error(suffix+' paged pixels differ '+JSON.stringify(paged));
  let foreground=0;for(let i=0;i<captures[0].length;i+=4)if(captures[0].slice(i,i+3).some((v,k)=>Math.abs(v-captures[0][k])>2))foreground++;
  if(foreground<20)throw Error('Blank glTF frame '+suffix);
  let reference=null;
  if(!suffix.includes('Mesh_PrimitiveMode')){
   const refPixels=await page.evaluate(async(path)=>{
    const {stream,website}=window.gltfTest,viewer=website.viewer,pager=stream.pager;
    const reference=await window.gltfReference(location.origin+'/imports/'+path);
    const previous=stream.root.children;stream.root.children=[reference];reference.parent=stream.root;
    viewer.renderer.setRenderTarget(pager.target);viewer.renderer.clear(true,true,true);viewer.renderer.render(viewer.scene,viewer.camera);
    viewer.renderer.setRenderTarget(null);const thumbnail=pager.Thumbnail();stream.root.children=previous;
    const b=await createImageBitmap(await(await fetch(thumbnail)).blob());const c=document.createElement('canvas');c.width=b.width;c.height=b.height;c.getContext('2d').drawImage(b,0,0);
    reference.traverse(o=>{if(o.geometry)o.geometry.dispose();if(o.material){for(const m of Array.isArray(o.material)?o.material:[o.material])m.dispose();}});
    return Array.from(c.getContext('2d').getImageData(0,0,c.width,c.height).data);
   },suffix==='sources/sparse-instances.glb'?'build/ios/gltf-stream-tests/sources/sparse-baked.glb':row.name);
   reference=compare(captures[1],refPixels);
   if(reference.meanAbsoluteError>1.5)throw Error('Independent glTF scene differs '+suffix+' '+JSON.stringify(reference));
  }
  await page.screenshot({path:'build/ios/gltf-stream-tests/'+suffix.split('/').slice(-1)[0]+'.png'});
  results.push({name:suffix,states,paged,reference});console.log('PASS',suffix,'paged',paged.mismatch,'reference',reference);
 }
 if(errors.length)throw Error(errors.join('\n'));
 fs.writeFileSync('build/ios/gltf-stream-tests/browser-results.json',JSON.stringify({passed:true,results,errors},null,2));await browser.close();
})().catch(e=>{console.error(e);process.exit(1)});
