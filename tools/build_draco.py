#!/usr/bin/env python3
"""Build pinned Draco with isolated, budgeted containers and cancellation checkpoints."""
import argparse
import hashlib
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
from urllib.request import urlopen

ROOT=Path(__file__).resolve().parent.parent
VERSION='1.5.7'
ARCHIVE_SHA256='bf6b105b79223eab2b86795363dfe5e5356050006a96521477973aba8f036fe1'


def prepare():
    archive=ROOT/f'build/ios/vendor-cache/draco-{VERSION}.tar.gz'
    archive.parent.mkdir(parents=True,exist_ok=True)
    if not archive.exists():archive.write_bytes(urlopen(f'https://codeload.github.com/google/draco/tar.gz/refs/tags/{VERSION}',timeout=60).read())
    assert hashlib.sha256(archive.read_bytes()).hexdigest()==ARCHIVE_SHA256,'Draco archive checksum mismatch'
    source=ROOT/'build/ios/draco-bounded-src'
    if (source/'O3DV_PATCHES.txt').exists():
        # Keep this one unqualified upstream use in sync with the renamed using declaration.
        p=source/'src/draco/attributes/point_attribute.cc'
        s=p.read_text();updated=s.replace('typedef unordered_map<','typedef o3dv::DracoUnorderedMap<')
        if updated!=s:p.write_text(updated)
        return source
    source.mkdir(parents=True,exist_ok=True)
    with tarfile.open(archive) as tar:
        prefix=tar.getmembers()[0].name+'/'
        for member in tar.getmembers():
            if not member.isfile() or not member.name.startswith(prefix):continue
            relative=Path(member.name[len(prefix):]);assert not relative.is_absolute() and '..' not in relative.parts
            path=source/relative;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(tar.extractfile(member).read())
    aliases={'vector':'DracoVector','map':'DracoMap','set':'DracoSet','unordered_map':'DracoUnorderedMap','unordered_set':'DracoUnorderedSet'}
    changed=[]
    for path in (source/'src/draco').rglob('*'):
        if path.suffix not in {'.h','.cc'}:continue
        text=path.read_text();original=text
        for name,replacement in aliases.items():
            text=re.sub(r'\bstd::'+name+r'\b','o3dv::'+replacement,text)
            # Account for the few source-local using declarations too.
        if text!=original:
            text=text.replace('typedef unordered_map<','typedef o3dv::DracoUnorderedMap<')
            text='#include "DracoMemory.hpp"\n'+text
            path.write_text(text);changed.append(str(path.relative_to(source)))
    def patch(name,before,after):
        path=source/'src/draco'/name;text=path.read_text();assert before in text,(name,before)
        path.write_text(text.replace(before,after))
    patch('core/decoder_buffer.h','  bool Decode(T *out_val) {','  bool Decode(T *out_val) {\n    o3dv::DracoCheckpoint();')
    patch('core/decoder_buffer.h','  bool Decode(void *out_data, size_t size_to_decode) {','  bool Decode(void *out_data, size_t size_to_decode) {\n    o3dv::DracoCheckpoint();')
    patch('core/data_buffer.h','  void Write(int64_t byte_pos, const void *in_data, size_t data_size) {','  void Write(int64_t byte_pos, const void *in_data, size_t data_size) {\n    o3dv::DracoCheckpoint();')
    patch('compression/attributes/attributes_decoder.cc','  point_attribute_ids_.resize(num_attributes);','  o3dv::DracoExternalBytes(size_t(num_attributes) * (sizeof(PointAttribute) + 256));\n  point_attribute_ids_.resize(num_attributes);')
    patch('metadata/metadata_decoder.cc','  name->resize(name_len);','  o3dv::DracoExternalBytes(size_t(name_len) * 3 + 256);\n  name->resize(name_len);')
    patch('metadata/metadata_decoder.cc','    std::unique_ptr<AttributeMetadata> att_metadata =','    o3dv::DracoExternalBytes(sizeof(AttributeMetadata));\n    std::unique_ptr<AttributeMetadata> att_metadata =')
    patch('metadata/metadata_decoder.cc','      std::unique_ptr<Metadata> sub_metadata =','      o3dv::DracoExternalBytes(sizeof(Metadata));\n      std::unique_ptr<Metadata> sub_metadata =')
    (source/'O3DV_PATCHES.txt').write_text('Pinned source with std vector/map/set/unordered containers bound to DracoMemory.hpp; checkpoint hooks in decoder input/data writes; conservative charges for small attribute/metadata objects and strings.\n'+'\n'.join(changed)+'\n')
    return source


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--platform',choices=['iphoneos','macosx'],default='iphoneos');parser.add_argument('--jobs',type=int,default=4);parser.add_argument('--sanitize',action='store_true');args=parser.parse_args()
    source=prepare();cmake=shutil.which('cmake')
    if not cmake:
        candidates=[ROOT/'build/ios/native-tools/bin/cmake',ROOT/'build/ios/model-analysis-env/bin/cmake']
        cmake=next((str(p) for p in candidates if p.exists()),None)
    if not cmake:
        tools=ROOT/'build/ios/native-tools'
        if not (tools/'bin/python').exists():subprocess.run([sys.executable,'-m','venv',str(tools)],check=True)
        subprocess.run([str(tools/'bin/python'),'-m','pip','install','--disable-pip-version-check','cmake==3.31.6'],check=True)
        cmake=str(tools/'bin/cmake')
    output=ROOT/'build/ios'/('draco-'+args.platform+('-sanitized' if args.sanitize else ''))
    sdk=subprocess.check_output(['xcrun','--sdk',args.platform,'--show-sdk-path'],text=True).strip()
    include=ROOT/'ios/Online3DViewer'
    flags=f'-I{include} -include {include}/DracoMemory.hpp -fexceptions'
    if args.sanitize:flags+=' -fsanitize=address,undefined -fno-omit-frame-pointer'
    command=[cmake,'-S',str(source),'-B',str(output),'-G','Unix Makefiles','-DCMAKE_BUILD_TYPE=RelWithDebInfo' if args.sanitize else '-DCMAKE_BUILD_TYPE=Release',
             '-DCMAKE_CXX_STANDARD=17','-DCMAKE_CXX_FLAGS='+flags,'-DCMAKE_OSX_ARCHITECTURES=arm64','-DCMAKE_OSX_SYSROOT='+sdk,
             '-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY','-DBUILD_SHARED_LIBS=OFF','-DDRACO_TESTS=OFF','-DDRACO_TRANSCODER_SUPPORTED=OFF','-DDRACO_INSTALL=OFF']
    command+=['-DCMAKE_SYSTEM_NAME=iOS','-DCMAKE_OSX_DEPLOYMENT_TARGET=17.0'] if args.platform=='iphoneos' else ['-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0']
    subprocess.run(command,check=True)
    subprocess.run([cmake,'--build',str(output),'--target','draco_static','--parallel',str(args.jobs)],check=True)
    print(f'Pinned Draco {VERSION} / {args.platform}: {output}',flush=True)


if __name__=='__main__':main()
