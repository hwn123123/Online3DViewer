// Browser-only instrumentation, served by the test route without changing packaged resources.
const esbuild=require('esbuild');const fs=require('fs');
esbuild.build({entryPoints:['source/website/index.js'],bundle:true,minify:true,globalName:'OV',
 outfile:'build/ios/gltf-stream-tests/gltf-test.min.js',loader:{'.ttf':'file','.woff':'file','.svg':'file'},
 plugins:[{name:'test-access',setup(build){build.onLoad({filter:/source\/website\/index\.js$/},args=>({
 contents:fs.readFileSync(args.path,'utf8').replace('const stream = new Native3dmStream (website);',
 'const stream = new Native3dmStream (website); window.gltfTest = {stream, website};'),loader:'js'}));}}]
}).catch(e=>{console.error(e);process.exit(1)});
