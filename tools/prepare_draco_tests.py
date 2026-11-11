#!/usr/bin/env python3
"""Prepare reproducible Draco fixtures; downloads happen on the development computer only."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
from urllib.parse import quote,unquote
from urllib.request import urlopen

ROOT=Path(__file__).resolve().parent.parent
OUTPUT=ROOT/'build/ios/draco-stream-tests'
REVISION='d7a3cc8e51d7c573771ae77a57f16b0662a905c6'


def main():
    output=OUTPUT/'draco3d';output.mkdir(parents=True,exist_ok=True)
    archive=ROOT/'build/ios/vendor-cache/draco3d-1.5.7.tgz'
    if not archive.exists():
        archive.parent.mkdir(parents=True,exist_ok=True)
        archive.write_bytes(urlopen('https://registry.npmjs.org/draco3d/-/draco3d-1.5.7.tgz',timeout=60).read())
    names={'package.json','draco_decoder_nodejs.js','draco_decoder.wasm','draco_encoder_nodejs.js','draco_encoder.wasm'}
    with tarfile.open(archive) as tar:
        for member in tar.getmembers():
            name=member.name.split('/')[-1]
            if member.isfile() and name in names:(output/name).write_bytes(tar.extractfile(member).read())
    assert json.loads((output/'package.json').read_text())['version']=='1.5.7'
    official=OUTPUT/'official';official.mkdir(exist_ok=True);records=[]
    for name in ['CesiumMan','Duck','CesiumMilkTruck']:
        base=f'https://raw.githubusercontent.com/KhronosGroup/glTF-Sample-Models/{REVISION}/2.0/{name}/glTF-Draco/'
        folder=official/name;folder.mkdir(exist_ok=True);primary=folder/(name+'.gltf')
        if not primary.exists():primary.write_bytes(urlopen(base+name+'.gltf',timeout=60).read())
        doc=json.loads(primary.read_text());uris=[x['uri'] for k in ['buffers','images'] for x in doc.get(k,[]) if x.get('uri') and not x['uri'].startswith('data:')]
        for uri in uris:
            relative=Path(unquote(uri));assert not relative.is_absolute() and '..' not in relative.parts and ':' not in str(relative)
            target=folder/relative;target.parent.mkdir(parents=True,exist_ok=True)
            if not target.exists():target.write_bytes(urlopen(base+quote(str(relative)),timeout=60).read())
        records.append({'name':name,'source':str(primary.relative_to(ROOT)),'url':base+name+'.gltf',
                        'generator':doc['asset'].get('generator'),'companions':uris,'sourceSHA256':hashlib.sha256(primary.read_bytes()).hexdigest()})
        print('Prepared official sample:',name,flush=True)
    (official/'sources.json').write_text(json.dumps(records,indent=2)+'\n')
    node=ROOT.parent/'.tools/node-v22.23.4-darwin-arm64/bin/node'
    if not node.exists():node=shutil.which('node')
    if not node:raise RuntimeError('Node.js is required to prepare independent WASM references')
    subprocess.run([str(node),'tools/decode_draco_references.cjs'],cwd=ROOT,check=True)
    subprocess.run([str(node),'tools/generate_draco_fixtures.cjs','--large'],cwd=ROOT,check=True)
    print('Draco references and large-file fixtures prepared; no phone data changed',flush=True)


if __name__=='__main__':main()
