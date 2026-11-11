#!/usr/bin/env python3
"""Build the pinned local DWG/DXF adapter and guarded acadrust source copy."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import build_cad_probe

ROOT = Path(__file__).resolve().parent.parent


def prepare():
    original = build_cad_probe.UPSTREAM
    if not original.exists():
        subprocess.run(['python3', str(ROOT / 'tools/build_cad_probe.py')], check=True)
    revision = subprocess.check_output(['git', '-C', str(original), 'rev-parse', 'HEAD'], text=True).strip()
    assert revision == build_cad_probe.REVISION
    target = ROOT / 'build/ios/acadrust-ios'
    guard = ROOT / 'ios/CadReader/src/guard.rs'
    recipe = hashlib.sha256(Path(__file__).read_bytes()+guard.read_bytes()).hexdigest()
    stamp = target / 'O3DV_PATCHES.json'
    if stamp.exists() and json.loads(stamp.read_text())['recipe'] == recipe:
        return target
    if target.exists():
        shutil.rmtree(target)
    shutil.copytree(original, target, ignore=shutil.ignore_patterns('.git', 'target'))
    counts = {'capacity': 0, 'vectors': 0, 'ticks': 0, 'resize': 0}
    for path in (target / 'src').rglob('*.rs'):
        text = path.read_text()
        text, n = re.subn(r'\bVec::with_capacity\(', 'crate::o3dv_guard::capacity(', text)
        counts['capacity'] += n
        for old, new in [('String','string'),('HashMap','hashmap'),('HashSet','hashset')]:
            if 'use foldhash::' in text and old in ['HashMap','HashSet']:
                new = 'foldmap' if old=='HashMap' else 'foldset'
            text, n = re.subn(r'(?<![\w:])'+old+r'::with_capacity\(', 'crate::o3dv_guard::'+new+'(', text)
            counts['capacity'] += n
        text, n = re.subn(r'(?<![\w:])vec!\[', 'crate::guarded_vec![', text)
        counts['vectors'] += n
        # Resize calls on section/page byte buffers can otherwise bypass the
        # capacity factories. Keep the original element count and contents.
        text, n = re.subn(r'\b([a-zA-Z_][\w.]*)\.resize\(([^;\n]*),\s*(0(?:u8)?|0\.0|false)\);',
                           r'crate::guarded_resize!(\1, \2, \3);', text)
        counts['resize'] += n
        path.write_text(text)
    def patch(name, before, after):
        path = target / 'src' / name
        text = path.read_text()
        assert before in text, (name, before)
        path.write_text(text.replace(before, after))
    with (target / 'src/lib.rs').open('a') as out:
        out.write('\npub mod o3dv_guard;\n')
    shutil.copy2(guard, target / 'src/o3dv_guard.rs')
    for method in ['read_byte(&mut self) -> u8', 'read_bit(&mut self) -> bool', 'read_2bits(&mut self) -> u8']:
        anchor = 'pub fn ' + method + ' {'
        patch('io/dwg/dwg_stream_readers/bit_reader.rs', anchor, anchor+'\n        crate::o3dv_guard::tick();')
        counts['ticks'] += 1
    for name in ['text_reader', 'binary_reader']:
        anchor = 'fn read_pair_internal(&mut self) -> Result<Option<DxfCodePair>> {'
        patch('io/dxf/reader/'+name+'.rs', anchor, anchor+'\n        crate::o3dv_guard::tick();')
        counts['ticks'] += 1
    # A DXF's file length is not a safe preallocation estimate (long comments,
    # images or text can dominate it). Grow at entity checkpoints instead.
    patch('io/dxf/reader.rs', 'document.entities.reserve(self.estimated_entities);',
          'document.entities.try_reserve(self.estimated_entities.min(4096)).map_err(|_| crate::DxfError::InvalidFormat("CAD allocation failed".into()))?;')
    patch('io/dxf/reader.rs', 'document.entity_index.reserve(self.estimated_entities);',
          'document.entity_index.try_reserve(self.estimated_entities.min(4096)).map_err(|_| crate::DxfError::InvalidFormat("CAD allocation failed".into()))?;')
    patch('document.rs', 'self.entities.reserve(additional);',
          'crate::o3dv_guard::checkpoint((self.entities.len().saturating_add(additional)).saturating_mul(std::mem::size_of::<Arc<EntityType>>()+64));\n'
          '        self.entities.try_reserve(additional).unwrap_or_else(|_| std::panic::panic_any(crate::o3dv_guard::Stop(2)));')
    patch('document.rs', 'self.entity_index.reserve(additional);',
          'self.entity_index.try_reserve(additional).unwrap_or_else(|_| std::panic::panic_any(crate::o3dv_guard::Stop(2)));')
    # Propagate guard failures out of optional-record recovery as soon as a new
    # read starts; the adapter also checks the sticky failure before publishing.
    stamp.write_text(json.dumps({'revision': revision, 'recipe': recipe, 'patchCounts': counts}, indent=2))
    print(counts, flush=True)
    return target


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--ios', action='store_true')
    parser.add_argument('--test', action='store_true')
    args = parser.parse_args()
    source = prepare()
    environment = dict(os.environ)
    local = ROOT / 'build/ios/rust-tools'
    if (local / 'cargo/bin/cargo').exists():
        environment.update(CARGO_HOME=str(local/'cargo'), RUSTUP_HOME=str(local/'rustup'))
        environment['PATH'] = str(local/'cargo/bin')+os.pathsep+environment['PATH']
    environment['CARGO_TARGET_DIR'] = str(ROOT/'build/ios/cad-target')
    manifest = ROOT/'ios/CadReader/Cargo.toml'
    command = ['cargo', 'build', '--release', '--locked', '--manifest-path', str(manifest)]
    if args.ios:
        command += ['--lib', '--target', 'aarch64-apple-ios']
    subprocess.run(command, check=True, cwd=ROOT, env=environment)
    metadata = json.loads(subprocess.check_output(['cargo','metadata','--locked','--format-version=1','--manifest-path',str(manifest)],cwd=ROOT,env=environment,text=True))
    notices=[]
    for package in metadata['packages']:
        folder=Path(package['manifest_path']).parent
        notices.append(f"\n{package['name']} {package['version']} — {package.get('license') or 'local adapter'}\n{package.get('repository') or ''}\n")
        for path in sorted(folder.iterdir()):
            if path.is_file() and path.name.upper().startswith(('LICENSE','COPYING','NOTICE','THIRD_PARTY_NOTICES')):
                notices.append(path.name+'\n'+path.read_text(errors='replace'))
    (ROOT/'build/ios/CAD_RUST_NOTICES.txt').write_text('\n'.join(notices))
    if args.test:
        subprocess.run(['cargo','test','--release','--manifest-path',str(manifest)], check=True,cwd=ROOT,env=environment)
    # Ship the exact covered source and modification recipe with the app.
    archive = ROOT/'build/ios/acadrust-app-source.tar.gz'
    with tarfile.open(archive,'w:gz') as tar:
        for name in ['src','Cargo.toml','LICENSE','THIRD_PARTY_NOTICES.md','O3DV_PATCHES.json']:
            path=source/name
            if path.exists():tar.add(path,arcname='acadrust/'+name)
        tar.add(Path(__file__),arcname='build_cad_reader.py')
    print('CAD library built', flush=True)


if __name__ == '__main__':
    main()
