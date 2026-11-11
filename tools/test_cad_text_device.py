#!/usr/bin/env python3
"""Verify native text, dimensions, glyph paging and cancellation on iPhone."""
import argparse
import json
from pathlib import Path
import test_stl_device as runner

ROOT=Path(__file__).resolve().parent.parent
BASE=ROOT/'build/ios/cad-text-tests'


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--device',required=True);parser.add_argument('--timeout',type=int,default=300);parser.add_argument('--only',type=int,nargs='+');args=parser.parse_args()
    runner.OUTPUT=BASE/'device';runner.OUTPUT.mkdir(parents=True,exist_ok=True);runner.CASE_PREFIX='99999999-9999-4999-8999-'
    native=json.loads((BASE/'native-results.json').read_text());work=[r for r in native if r.get('path')]
    sources=BASE/'sources'
    names=['mtext','attributes','saved-dimension','generated-normal','generated-suppressed','chinese-hole','transformed']
    cases=[(i+1,sources/(name+'.dxf'),'model_loaded',{},name)for i,name in enumerate(names)]
    for row in work:cases.append((len(cases)+1,Path(row['path']),'model_loaded',{},row['cache']))
    resource=Path(max(work,key=lambda row:Path(row['path']).stat().st_size)['path'])
    start=len(cases)+1
    cases += [(start,sources/'mtext.dxf','load_cancelled',{'cancelAfterReadBytes':1},'mtext'),
              (start+1,resource,'resource_limit',{'decoderBudgetBytes':512*1024},None),
              (start+2,sources/'mtext.dxf','model_loaded',{},'mtext'),
              (start+3,ROOT/'build/ios/cad-stream-tests/sources/bad-header.dwg','native_read_error',{},None),
              (start+4,ROOT/'test/testfiles/gltf/Box/glTF-Draco/Box.gltf','model_loaded',{'companions':['Box.bin']},None),
              (start+5,ROOT/'build/ios/WebAssets/assets/models/utah_teapot.stl','model_loaded',{},None),
              (start+6,ROOT/'build/ios/skp-stream-tests/sources/basic.skp','model_loaded',{},None)]
    for name in ['mtext-wide','wrap-wide','underline-range','chinese-overlap']:
        cases.append((len(cases)+1,sources/(name+'.dxf'),'model_loaded',{},name))
    results_file=runner.OUTPUT/'results.json';results=json.loads(results_file.read_text())if results_file.exists()else[]
    for number,source,expected,settings,cache in cases:
        if args.only and number not in args.only:continue
        triangles=12 if source.suffix=='.gltf' else 9438 if source.suffix=='.stl' else None
        row=runner.run_case(args,number,source,expected,triangles,4*1048576,**settings)
        if expected=='model_loaded' and cache:
            phone=row['state']['details'];reference=json.loads((BASE/'caches'/cache/'manifest.json').read_text())
            assert phone['complete'] and phone['displayed']==phone['objectCount'],phone
            assert phone['reader']=='cad-stream-4' and phone['textObjects']==reference['textObjects'] and phone['dimensionObjects']==reference['dimensionObjects'],phone
            assert phone['nativePeakFootprintBytes']<512*1048576,phone
            assert phone['textObjects']==0 or phone['triangles']>0,phone
            if phone['unsupportedCount']:assert not phone['coverageComplete'] and phone['warnings'],phone
            # System fallback fonts can differ between macOS and iOS; they do
            # not have to produce identical triangle counts or line wrapping.
        results=[r for r in results if r['number']!=number]+[row];results_file.write_text(json.dumps(sorted(results,key=lambda r:r['number']),ensure_ascii=False,indent=2)+'\n')


if __name__=='__main__':main()
