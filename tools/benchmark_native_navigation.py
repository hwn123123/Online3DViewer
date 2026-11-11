#!/usr/bin/env python3
"""Repeat identical in-app camera motions using isolated complete cache fixtures."""
import argparse,json,subprocess,time
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent
BASE=ROOT/'build/ios/render-performance-tests'
DOMAIN=['--domain-type','appDataContainer','--domain-identifier','com.hwn.Online3DViewer']
CASES=[('many-instances',101,2*1048576),('distinct-blocks',102,1048576),('legacy-blocks',103,1048576),('work-obj',104,64*1048576),('work-fbx',105,64*1048576),('work-rhino',106,64*1048576)]
def device(args,command,timeout=120):
 for attempt in range(3):
  r=subprocess.run(['xcrun','devicectl','device',*command[:2],'--device',args.device,*command[2:]],capture_output=True,text=True,timeout=timeout)
  if not r.returncode:return r
  message=(r.stderr or r.stdout)[-2000:]
  if command[:2]!=['process','launch'] or '10004' not in message:raise RuntimeError(message)
  time.sleep(1)
 raise RuntimeError(message)

def main():
 p=argparse.ArgumentParser();p.add_argument('--device',required=True);p.add_argument('--stage',required=True);p.add_argument('--only',nargs='+');p.add_argument('--transfer',action='store_true');p.add_argument('--timeout',type=int,default=360);args=p.parse_args()
 output=BASE/args.stage;output.mkdir(parents=True,exist_ok=True);result_file=output/'device-benchmarks.json';results=json.loads(result_file.read_text()) if result_file.exists() else []
 for name,number,budget in CASES:
  if args.only and name not in args.only:continue
  uid=f'33333333-3333-4333-8333-000000000{number}';fixture=BASE/'fixtures'/uid
  if args.transfer:
   device(args,['copy','to',*DOMAIN,'--source',str(fixture),'--destination','Library/Caches/ModelImports/FormatAudit/'+uid])
  run=f'--test-run=render-benchmark-{args.stage}-{number}'
  device(args,['process','launch','--terminate-existing','com.hwn.Online3DViewer','--','--audit-case='+uid,'--benchmark-navigation',run])
  start=time.monotonic();last=None
  while time.monotonic()-start<args.timeout:
   target=output/(name+'-live.json')
   r=subprocess.run(['xcrun','devicectl','device','copy','from','--device',args.device,*DOMAIN,'--source','Library/Caches/navigation-benchmark.json','--destination',str(target)],capture_output=True,timeout=20)
   if not r.returncode:
    state=json.loads(target.read_text())
    if state.get('testRun')==run:
     if state['event']!='navigation_benchmark_complete':raise RuntimeError(state)
     results=[row for row in results if row['name']!=name];results.append({'name':name,'budget':budget,'elapsedSeconds':round(time.monotonic()-start,2),'state':state});break
   status=output/(name+'-progress.json')
   r=subprocess.run(['xcrun','devicectl','device','copy','from','--device',args.device,*DOMAIN,'--source','Library/Caches/viewer-status.json','--destination',str(status)],capture_output=True,timeout=20)
   if not r.returncode:
    state=json.loads(status.read_text())
    if state.get('testRun')==run:
     fields=state.get('details',{});message=(state['event'],fields.get('displayed'),fields.get('frameSerial'))
     if message!=last:print(name,message,flush=True);last=message
     if state['event'] in ['javascript_error','webcontent_terminated','resource_limit']:raise RuntimeError(state)
   time.sleep(1)
  else:raise TimeoutError(name)
  (output/'device-benchmarks.json').write_text(json.dumps(results,ensure_ascii=False,indent=2))
  print(name,[round(x['elapsedMs'],1) for x in results[-1]['state']['details']['results']],flush=True)
if __name__=='__main__':main()
