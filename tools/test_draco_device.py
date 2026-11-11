#!/usr/bin/env python3
"""Run isolated native Draco cases through the actual installed iPhone app."""
import argparse
import json
from pathlib import Path
import test_stl_device as runner

ROOT=Path(__file__).resolve().parent.parent
BASE=ROOT/'build/ios/draco-stream-tests'


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--device',required=True)
    parser.add_argument('--timeout',type=int,default=240);parser.add_argument('--only',type=int,nargs='+');args=parser.parse_args()
    runner.OUTPUT=BASE/'device';runner.OUTPUT.mkdir(parents=True,exist_ok=True)
    runner.CASE_PREFIX='66666666-6666-4666-8666-'
    source=BASE/'sources';official=BASE/'official';models=ROOT/'build/ios/WebAssets/assets/models'
    cases=[
        (1,ROOT/'test/testfiles/gltf/Box/glTF-Draco/Box.gltf','model_loaded',12,262144,{'companions':['Box.bin']}),
        (2,official/'CesiumMilkTruck/CesiumMilkTruck.gltf','model_loaded',3624,262144,{'companions':['CesiumMilkTruck_data.bin','CesiumMilkTruck.jpg']}),
        (3,official/'CesiumMan/CesiumMan.gltf','model_loaded',4672,262144,{'companions':['CesiumMan_data.bin','CesiumMan_img0.jpg']}),
        (4,official/'Duck/Duck.gltf','model_loaded',4212,262144,{'companions':['Duck.bin','DuckCM.png']}),
        (5,source/'strip.glb','model_loaded',104,262144,{}),
        (6,source/'mixed.glb','model_loaded',84,262144,{}),
        (7,source/'instances.glb','model_loaded',168,262144,{}),
        (8,source/'large.glb','model_loaded',1045506,8*1048576,{}),
        (9,source/'large.glb','load_cancelled',None,8*1048576,{'cancelAfterDecoderBytes':4*1048576}),
        (10,source/'large.glb','model_loaded',1045506,8*1048576,{}),
        (11,source/'large.glb','resource_limit',None,8*1048576,{'decoderBudgetBytes':512*1024}),
        (12,source/'invalid-header.glb','native_read_error',None,8*1048576,{}),
        (13,source/'negative-attribute-id.glb','native_read_error',None,8*1048576,{}),
        (14,models/'DamagedHelmet.glb','model_loaded',15452,8*1048576,{}),
        (15,models/'utah_teapot.stl','model_loaded',9438,262144,{}),
        (16,models/'RhinoLogo.3dm','model_loaded',None,8*1048576,{}),
    ]
    output=runner.OUTPUT/'results.json';results=json.loads(output.read_text()) if output.exists() else []
    for number,path,expected,triangles,budget,settings in cases:
        if args.only and number not in args.only:continue
        row=runner.run_case(args,number,path,expected,triangles,budget,**settings)
        if expected=='model_loaded' and number<=10:
            assert row['state']['details'].get('dracoDecodedPrimitiveCount',0)>0,row
        if number==7:assert row['state']['details']['dracoDecodedPrimitiveCount']==1,row
        results=[r for r in results if r['number']!=number]+[row]
        output.write_text(json.dumps(sorted(results,key=lambda r:r['number']),ensure_ascii=False,indent=2)+'\n')


if __name__=='__main__':main()
