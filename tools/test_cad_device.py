#!/usr/bin/env python3
"""Exercise CAD loading, coverage reporting and recovery on the installed app."""
import argparse
import json
from pathlib import Path
import test_stl_device as runner

ROOT=Path(__file__).resolve().parent.parent
BASE=ROOT/'build/ios/cad-stream-tests'


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--device',required=True);parser.add_argument('--timeout',type=int,default=240);parser.add_argument('--only',type=int,nargs='+');args=parser.parse_args()
    runner.OUTPUT=BASE/'device';runner.OUTPUT.mkdir(parents=True,exist_ok=True);runner.CASE_PREFIX='88888888-8888-4888-8888-'
    sources=BASE/'sources';reference=ROOT/'build/ios/acadrust-upstream/tests/fixtures/r12/cad-created/native-geometry.dxf'
    rows=json.loads((BASE/'native-results.json').read_text());work=[r for r in rows if r.get('path')]
    cases=[(1,reference,'model_loaded',None,{}),(2,sources/'instances.dxf','model_loaded',0,{}),(3,sources/'curves.dxf','model_loaded',0,{})]
    # macOS and iOS may use different system fallback fonts for CAD text.
    for i,row in enumerate(work,4):cases.append((i,Path(row['path']),'model_loaded',None,{}))
    number=len(cases)+1
    cancel_source=Path(next(r['path'] for r in work if r.get('version')=='AC1015'))
    resource_source=Path(max(work,key=lambda row:Path(row['path']).stat().st_size)['path'])
    cases += [(number,sources/'concave.dxf','model_loaded',3,{}),
              (number+1,resource_source,'resource_limit',None,{'decoderBudgetBytes':512*1024}),
              (number+2,sources/'bad-header.dwg','native_read_error',None,{}),
              (number+3,cancel_source,'load_cancelled',None,{'cancelAfterReadBytes':1}),
              (number+4,sources/'instances.dxf','model_loaded',0,{}),
              (number+5,ROOT/'test/testfiles/gltf/Box/glTF-Draco/Box.gltf','model_loaded',12,{'companions':['Box.bin']}),
              (number+6,ROOT/'build/ios/WebAssets/assets/models/utah_teapot.stl','model_loaded',9438,{}),
              (number+7,ROOT/'build/ios/skp-stream-tests/sources/basic.skp','model_loaded',2,{})]
    output=runner.OUTPUT/'results.json';results=json.loads(output.read_text()) if output.exists() else []
    for number,source,expected,triangles,settings in cases:
        if args.only and number not in args.only:continue
        row=runner.run_case(args,number,source,expected,triangles,2*1048576,**settings)
        if source.suffix.lower() in {'.dwg','.dxf'} and expected=='model_loaded':
            state=row['state']['details'];assert state['reader']=='cad-stream-4',state
            assert state['complete'] and state['displayed']==state['objectCount'],state
            assert state['nativePeakFootprintBytes']<512*1048576,state
            if state['unsupportedCount']:
                assert state['coverageComplete'] is False and state['warnings'],state
        results=[r for r in results if r['number']!=number]+[row];output.write_text(json.dumps(sorted(results,key=lambda r:r['number']),ensure_ascii=False,indent=2)+'\n')


if __name__=='__main__':main()
