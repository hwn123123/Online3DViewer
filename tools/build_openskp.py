#!/usr/bin/env python3
"""Build the pinned OpenSKP reader without exporters or their dependencies."""
import argparse
import hashlib
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parent.parent
COMMIT = 'c98561147ea502c6d4d53a257fa4581d0c6cde1d'
MINIZ = '77d0dce8627735138c51770d1799a1ef48f2117d'
PACKAGES = [
    ('openskp', COMMIT, 'iamahsanmehmood/openskp', '00931aac70223c7caa3b9400904a81896046b9feb8c1e9fb3ea2787cfa235e63'),
    ('miniz', MINIZ, 'richgel999/miniz', 'baa14349e7c5efb4a493a03af7d2f29d0ef45d87d488567fe5360edb33f8b7ba'),
]
SOURCES = ['core', 'parser', 'model', 'scene', 'instanced_scene', 'face_groups', 'legacy',
           'geometry', 'tlv', 'vff', 'transforms', 'triangulator', 'earcut', 'errors',
           'observability', 'pages_dimensions']


def prepare():
    base = ROOT / 'build/ios'
    paths = {}
    for name, commit, repo, checksum in PACKAGES:
        archive = base / f'vendor-cache/{name}-{commit}.tar.gz'
        archive.parent.mkdir(parents=True, exist_ok=True)
        if not archive.exists():
            archive.write_bytes(urlopen(f'https://codeload.github.com/{repo}/tar.gz/{commit}', timeout=60).read())
        if hashlib.sha256(archive.read_bytes()).hexdigest() != checksum:
            raise RuntimeError(f'{name} archive checksum mismatch')
        target = base / f'{name}-skp-src'
        if not (target / '.o3dv-source').exists():
            target.mkdir(parents=True, exist_ok=True)
            with tarfile.open(archive) as tar:
                prefix = tar.getmembers()[0].name + '/'
                for member in tar.getmembers():
                    if not member.isfile() or not member.name.startswith(prefix):
                        continue
                    relative = Path(member.name[len(prefix):])
                    assert not relative.is_absolute() and '..' not in relative.parts
                    path = target / relative
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(tar.extractfile(member).read())
            (target / '.o3dv-source').write_text(commit + '\n')
        paths[name] = target
    return paths


def bounded_source(original):
    source = ROOT / 'build/ios/openskp-bounded-src'
    # Regenerate only if the patch recipe or allocator changed.
    recipe = hashlib.sha256(Path(__file__).read_bytes() + (ROOT / 'ios/Online3DViewer/SkpMemory.hpp').read_bytes()).hexdigest()
    stamp = source / 'O3DV_PATCHES.txt'
    if stamp.exists() and stamp.read_text().startswith(recipe):
        return source
    if source.exists():
        shutil.rmtree(source)
    shutil.copytree(original / 'packages/cpp', source)
    aliases = {'vector': 'SkpVector', 'deque': 'SkpDeque', 'map': 'SkpMap', 'set': 'SkpSet',
               'unordered_map': 'SkpUnorderedMap', 'unordered_set': 'SkpUnorderedSet', 'make_shared': 'SkpMakeShared'}
    for root in [source / 'include', source / 'src']:
        for path in root.rglob('*'):
            if path.suffix not in {'.hpp', '.cpp'}:
                continue
            text = path.read_text()
            for name, replacement in aliases.items():
                text = re.sub(r'\bstd::' + name + r'\b', 'o3dv::' + replacement, text)
            # Optional-record recovery must never swallow cancellation/resource errors.
            text = re.sub(r'(catch\s*\([^)]*\)\s*\{)', r'\1 o3dv::SkpCheck();', text)
            path.write_text('#include "SkpMemory.hpp"\n' + text)
    def patch(name, before, after):
        path = source / name
        text = path.read_text()
        if before not in text:
            raise RuntimeError(f'OpenSKP patch anchor missing: {name}: {before[:80]}')
        path.write_text(text.replace(before, after))
    # Expose the source face layer/visibility in the groups written to App caches.
    patch('src/face_groups.hpp', '  bool operator<(const GroupKey& other) const {',
          '  std::string layer;\n  bool hidden{};\n  bool operator<(const GroupKey& other) const {')
    patch('src/face_groups.hpp', 'std::tie(color, double_sided, texture_index)', 'std::tie(color, double_sided, texture_index, layer, hidden)')
    patch('src/face_groups.hpp', 'std::tie(other.color, other.double_sided, other.texture_index)', 'std::tie(other.color, other.double_sided, other.texture_index, other.layer, other.hidden)')
    patch('src/face_groups.hpp', '  FaceColorKey fallback_color{};',
          '  FaceColorKey fallback_color{};\n  std::shared_ptr<RawMaterial> inherited_material;')
    patch('src/face_groups.cpp', 'find_material(parsed, f.material_id);',
          'f.material_id ? find_material(parsed, f.material_id) : ctx.inherited_material;')
    patch('src/face_groups.cpp', 'find_material(parsed, f.back_material_id);',
          'f.back_material_id ? find_material(parsed, f.back_material_id) : ctx.inherited_material;')
    patch('src/face_groups.cpp', '    if (front == back) {',
          '    const auto front_texture = ctx.texture_index_for(front_mat);\n'
          '    const auto back_texture = ctx.texture_index_for(back_mat);\n'
          '    std::string face_layer=f.layer;\n'
          '    if(!f.layer.empty())try { auto it=parsed.layer_id_to_name.find(std::stoll(f.layer)); if(it!=parsed.layer_id_to_name.end())face_layer=it->second; } catch(...) {o3dv::SkpCheck();}\n'
          '    if (front == back && front_texture == back_texture && f.uv_transform == f.uv_transform_back) {')
    patch('src/face_groups.cpp', 'ctx.texture_index_for(front_mat)},', 'front_texture, face_layer, f.hidden},')
    patch('src/face_groups.cpp', 'ctx.texture_index_for(back_mat)},', 'back_texture, face_layer, f.hidden},')
    patch('src/face_groups.cpp', '  for (auto& fv : b.faces) {', '  for (auto& fv : b.faces) { o3dv::SkpTick();')
    # Reads and long topology walks stay interruptible even without allocating.
    for name in ['src/legacy.cpp', 'src/tlv.cpp', 'src/geometry.cpp', 'src/triangulator.cpp', 'src/core.cpp']:
        path = source / name
        text = path.read_text()
        text = re.sub(r'(for\s*\([^\n{}]*\)\s*\{)', r'\1 o3dv::SkpTick();', text)
        path.write_text(text)
    stamp.write_text(recipe + '\nPinned reader-only source. Budgeted containers/shared nodes; mapped small-node slabs; checkpoints and resource-error propagation; face layers/hidden flags; inherited and front/back textured materials.\n')
    return source


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--platform', choices=['macosx', 'iphoneos'], default='iphoneos')
    parser.add_argument('--jobs', type=int, default=4)
    parser.add_argument('--reference', action='store_true')
    parser.add_argument('--sanitize', action='store_true')
    args = parser.parse_args()
    paths = prepare()
    base = ROOT / 'build/ios'
    project = base / ('openskp-reference-project' if args.reference else 'openskp-reader-project')
    project.mkdir(exist_ok=True)
    include = project / 'include'
    (include / 'openskp').mkdir(parents=True, exist_ok=True)
    (include / 'openskp/export.hpp').write_text('#pragma once\n#define OPENSKP_EXPORT\n')
    (include / 'miniz_export.h').write_text('#pragma once\n#define MINIZ_EXPORT\n')
    cpp = paths['openskp'] / 'packages/cpp' if args.reference else bounded_source(paths['openskp'])
    sources = [cpp / f'src/{name}.cpp' for name in SOURCES]
    sources += [paths['miniz'] / name for name in ['miniz.c', 'miniz_tdef.c', 'miniz_tinfl.c', 'miniz_zip.c']]
    cmake_text = 'cmake_minimum_required(VERSION 3.21)\nproject(O3DVOpenSkp LANGUAGES C CXX)\n'
    cmake_text += 'add_library(openskp STATIC\n' + '\n'.join(f'"{p}"' for p in sources) + '\n)\n'
    cmake_text += f'target_include_directories(openskp PUBLIC "{cpp}/include" "{include}" PRIVATE "{paths["miniz"]}")\n'
    cmake_text += 'target_compile_features(openskp PUBLIC cxx_std_17)\n'
    if not args.reference:
        cmake_text += f'target_include_directories(openskp PUBLIC "{ROOT}/ios/Online3DViewer")\n'
    (project / 'CMakeLists.txt').write_text(cmake_text)
    cmake = shutil.which('cmake')
    if not cmake:
        cmake = next((str(p) for p in [base / 'native-tools/bin/cmake', base / 'model-analysis-env/bin/cmake'] if p.exists()), None)
    if not cmake:
        native_tools = base / 'native-tools'
        if not (native_tools / 'bin/python').exists():
            subprocess.run([sys.executable, '-m', 'venv', str(native_tools)], check=True)
        subprocess.run([str(native_tools / 'bin/python'), '-m', 'pip', 'install', '--disable-pip-version-check', 'cmake==3.31.6'], check=True)
        cmake = str(native_tools / 'bin/cmake')
    output = base / (('openskp-reference' if args.reference else f'openskp-{args.platform}') + ('-sanitized' if args.sanitize else ''))
    sdk = subprocess.check_output(['xcrun', '--sdk', args.platform, '--show-sdk-path'], text=True).strip()
    command = [cmake, '-S', str(project), '-B', str(output), '-G', 'Unix Makefiles',
               '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_OSX_ARCHITECTURES=arm64',
               '-DCMAKE_OSX_SYSROOT=' + sdk, '-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY']
    command += ['-DCMAKE_SYSTEM_NAME=iOS', '-DCMAKE_OSX_DEPLOYMENT_TARGET=17.0'] if args.platform == 'iphoneos' else ['-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0']
    if args.sanitize:
        command += ['-DCMAKE_CXX_FLAGS=-fsanitize=address,undefined -fno-omit-frame-pointer',
                    '-DCMAKE_C_FLAGS=-fsanitize=address,undefined -fno-omit-frame-pointer']
    subprocess.run(command, check=True)
    subprocess.run([cmake, '--build', str(output), '--parallel', str(args.jobs)], check=True)
    print(f'Pinned OpenSKP {COMMIT}: {output}', flush=True)


if __name__ == '__main__':
    main()
