#!/usr/bin/env python3
"""Isolated real iPhone regression for native GLB/glTF conversion and display."""
import argparse
import json
from pathlib import Path
import test_stl_device as runner

ROOT=Path(__file__).resolve().parent.parent
BASE=ROOT/'build/ios/gltf-stream-tests'
SOURCE=BASE/'sources'


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--device',required=True)
    parser.add_argument('--timeout',type=int,default=180);parser.add_argument('--only',type=int,nargs='+')
    args=parser.parse_args()
    runner.OUTPUT=BASE/'device';runner.OUTPUT.mkdir(parents=True,exist_ok=True)
    runner.CASE_PREFIX='55555555-5555-4555-8555-'
    fixtures=ROOT/'test/testfiles/gltf'
    cases=[
        (1,fixtures/'DamagedHelmet/glTF-Binary/DamagedHelmet.glb','model_loaded',15452,8*1048576,{}),
        (2,fixtures/'BoxTextured/glTF/BoxTextured.gltf','model_loaded',12,262144,{'companions':['BoxTextured0.bin','CesiumLogoFlat.png']}),
        (3,fixtures/'BoxTextured/glTF-Embedded/BoxTextured.gltf','model_loaded',12,262144,{}),
        (4,SOURCE/'materials.gltf','model_loaded',8,262144,{'companions':['material.bin','color.png','normal.png','surface.png']}),
        (5,SOURCE/'sparse-instances.glb','model_loaded',2,262144,{}),
        (6,SOURCE/'morph.glb','model_loaded',2,262144,{}),
        (7,SOURCE/'skin.glb','model_loaded',1,262144,{}),
        (8,SOURCE/'large.glb','model_loaded',1048576,8*1048576,{}),
        (9,SOURCE/'large.glb','load_cancelled',None,2*1048576,{'cancelAfterReadBytes':1}),
        (10,SOURCE/'large.glb','model_loaded',1048576,8*1048576,{}),
        (11,SOURCE/'overflow-accessor.glb','native_read_error',None,2*1048576,{}),
        (12,fixtures/'Box/glTF-Draco/Box.gltf','model_loaded',12,2*1048576,{'companions':['Box.bin']}),
        (13,ROOT/'build/ios/WebAssets/assets/models/utah_teapot.stl','model_loaded',9438,262144,{}),
        (14,ROOT/'build/ios/WebAssets/assets/models/RhinoLogo.3dm','model_loaded',None,8*1048576,{}),
        (15,fixtures/'Mesh_PrimitiveMode/Mesh_PrimitiveMode_00.gltf','model_loaded',0,262144,{'companions':['Mesh_PrimitiveMode_00.bin']}),
    ]
    output=runner.OUTPUT/'results.json';results=json.loads(output.read_text()) if output.exists() else []
    for number,path,expected,triangles,budget,settings in cases:
        if args.only and number not in args.only:continue
        row=runner.run_case(args,number,path,expected,triangles,budget,**settings)
        results=[r for r in results if r['number']!=number]+[row]
        output.write_text(json.dumps(sorted(results,key=lambda r:r['number']),ensure_ascii=False,indent=2)+'\n')


if __name__=='__main__':main()
