#!/usr/bin/env python3
"""Compare Android 3DM device output with independently prepared reference caches."""
import argparse,json,subprocess,time,tarfile,shutil,sys
from pathlib import Path
from urllib.parse import urlparse
root=Path(__file__).resolve().parent.parent;out=root/'build/android-tests/rhino';out.mkdir(parents=True,exist_ok=True)
parser=argparse.ArgumentParser();parser.add_argument('--adb',default='adb');parser.add_argument('--device',required=True);args=parser.parse_args()
adb=[args.adb,'-s',args.device];pkg='com.hwn.modelviewer'
def run(*args,check=True):return subprocess.run(adb+list(map(str,args)),capture_output=True,text=True,check=check,timeout=90).stdout
# Generate the reference fixtures with tools/test_rhino_instances.py and build/ios/rhino-stream first.
cases=[('logo',root/'build/ios/WebAssets/assets/models/RhinoLogo.3dm',root/'build/android-tests/rhino-reference/logo/manifest.json'),('nested',root/'build/ios/rhino-geometry-tests/source-fixtures/nested-affine.3dm',root/'build/ios/rhino-geometry-tests/affine/manifest.json'),('curves',root/'build/ios/opennurbs-src/example_files/V6/my_curves.3dm',None),('missing',root/'build/ios/rhino-geometry-tests/source-fixtures/missing-member.3dm',None)]
mixed=root/'build/android-tests/mixed-fixtures/mixed-batches.3dm';mixed_reference=root/'build/android-tests/mixed-reference/manifest.json'
if mixed.exists() and mixed_reference.exists():cases.append(('mixed',mixed,mixed_reference))
else:print('SKIP mixed batching and instances: prepare generated fixture and reference',flush=True)
for name,source,reference in cases:
 run('shell','am','force-stop',pkg);run('shell','run-as',pkg,'rm','-f','cache/android-test-fixture.3dm','cache/viewer-debug-status.json')
 run('push',source,'/data/local/tmp/o3dv-fixture.3dm');run('shell','run-as',pkg,'cp','/data/local/tmp/o3dv-fixture.3dm','cache/android-test-fixture.3dm')
 run('shell','am','start','-S','-n',pkg+'/.MainActivity','--ez','debug-library-test','true','--es','debug-sample','fixture3dm')
 for i in range(120):
  raw=run('shell','run-as',pkg,'cat','cache/viewer-debug-status.json',check=False)
  try: state=json.loads(raw)
  except:time.sleep(.5);continue
  if state.get('type') in ('model_loaded','native_read_error','javascript_error'):break
  time.sleep(.5)
 else:raise RuntimeError((name,'timeout',raw))
 assert state.get('type')=='model_loaded',(name,state)
 ident=urlparse(state['manifestUrl']).path.split('/')[2]
 assert len(ident)==36 and all(c in '0123456789abcdef-' for c in ident)
 target=out/name;shutil.rmtree(target,ignore_errors=True);target.mkdir()
 archive=target/'cache.tar'
 with archive.open('wb') as fd:subprocess.run(adb+['exec-out','run-as',pkg,'tar','-C','files/model-library-test/'+ident,'-cf','-','stream'],stdout=fd,check=True,timeout=90)
 with tarfile.open(archive) as f:
  for m in f.getmembers():assert (m.name=='stream' or m.name.startswith('stream/')) and '..' not in Path(m.name).parts and not m.issym() and not m.islnk()
  f.extractall(target)
 archive.unlink();manifest=json.loads((target/'stream/manifest.json').read_text())
 assert manifest['complete'] and manifest['reader']=='opennurbs-android-1'
 if reference and name!='mixed':
  ref=json.loads(reference.read_text())
  for field in ('sourceObjectCount','triangles','vertices','lineSegments'):
   assert manifest[field]==ref[field],(name,field,manifest[field],ref[field])
  a={o['id']:o for o in manifest['objects']};b={o['id']:o for o in ref['objects']}
  assert a.keys()==b.keys(),(name,'object ids',len(a),len(b),list(a.keys()-b.keys())[:3],list(b.keys()-a.keys())[:3])
  for key in a:
   for field in ('type','layerIndex','materialIndex','visible','definitionMember','triangles','vertices','lineSegments','color','lineColor','opacity','origin','transform','bounds'):
    if field in a[key] or field in b[key]:
     x,y=a[key].get(field),b[key].get(field)
     if isinstance(x,list) and isinstance(y,list) and all(isinstance(v,(int,float)) for v in x+y):assert len(x)==len(y) and all(abs(j-k)<1e-6 for j,k in zip(x,y)),(name,key,field,x,y)
     else: assert x==y,(name,key,field,x,y)
   for field in ('url',):
    if a[key].get('available') and b[key].get('available'):
     assert (target/'stream'/a[key][field]).read_bytes()==(reference.parent/b[key][field]).read_bytes(),(name,key,'geometry differs')
 if name=='mixed':
  assert any(o.get('parts') for o in manifest['objects']), 'mixed fixture did not exercise batching'
  assert any(o.get('instanceId') for o in manifest['objects']), 'mixed fixture lost instances'
  subprocess.run([sys.executable,str(root/'tools/verify_android_rhino_batches.py'),'--reference',str(reference.parent),'--android',str(target/'stream'),'--samples','2000'],check=True)
 if name=='missing': assert manifest['unsupported'],manifest
 (target/'state.json').write_text(json.dumps(state,ensure_ascii=False,indent=2));print('PASS',name,'source',manifest['sourceObjectCount'],'objects',manifest['objectCount'],'triangles',manifest['triangles'],'unsupported',len(manifest['unsupported']),flush=True)
run('shell','run-as',pkg,'rm','-f','cache/android-test-fixture.3dm');run('shell','rm','-f','/data/local/tmp/o3dv-fixture.3dm')
