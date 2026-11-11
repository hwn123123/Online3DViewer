#!/usr/bin/env python3
"""Prepare the self-contained web resources used by the iOS application."""
import concurrent.futures
import json
from pathlib import Path
import shutil
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / 'build' / 'ios'
PACKAGES = [
    ('rhino3dm', '8.17.0', 'rhino3dm', ['rhino3dm.min.js', 'rhino3dm.wasm']),
    ('web-ifc', '0.0.68', 'webifc', ['web-ifc-api-iife.js', 'web-ifc.wasm']),
    ('draco3d', '1.5.7', 'draco3d', ['draco_decoder_nodejs.min.js', 'draco_decoder.wasm']),
    ('occt-import-js', '0.0.22', 'occt', [
        'dist/occt-import-js-worker.js', 'dist/occt-import-js.js', 'dist/occt-import-js.wasm'
    ]),
]


def download_package(package):
    name, version, _, _ = package
    cache = OUTPUT / 'vendor-cache'
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / f'{name}-{version}.tgz'
    if not archive.exists():
        temporary = archive.with_suffix('.download')
        url = f'https://registry.npmjs.org/{name}/-/{name}-{version}.tgz'
        subprocess.run(['curl', '-fsSL', '--retry', '3', '--connect-timeout', '15',
                        '--max-time', '180', url, '-o', str(temporary)], check=True)
        with tarfile.open(temporary, 'r:gz'):
            pass
        temporary.replace(archive)
    print(f'Ready: {name}@{version}', flush=True)
    return archive


def main():
    website = ROOT / 'build' / 'package' / 'website'
    if not (website / 'o3dv' / 'o3dv.website.min.js').exists():
        raise SystemExit('Run npm run create_package first.')
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
        archives = list(executor.map(download_package, PACKAGES))
    destination = OUTPUT / 'WebAssets'
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(website, destination)
    notices = []
    for package, archive in zip(PACKAGES, archives):
        name, version, directory, filenames = package
        target = destination / 'assets' / 'libs' / directory
        target.mkdir(parents=True, exist_ok=True)
        with tarfile.open(archive, 'r:gz') as tar:
            for filename in filenames:
                try:
                    member = tar.getmember('package/' + filename)
                except KeyError:
                    # jsDelivr also serves .min.js names generated from the npm source.
                    if not filename.endswith('.min.js'):
                        raise
                    member = tar.getmember('package/' + filename.replace('.min.js', '.js'))
                with tar.extractfile(member) as source:
                    (target / Path(filename).name).write_bytes(source.read())
            licenses = [member for member in tar.getmembers()
                        if member.isfile() and Path(member.name).name.lower().startswith(('license', 'copying'))]
            for index, member in enumerate(licenses):
                with tar.extractfile(member) as source:
                    content = source.read()
                    (target / f'LICENSE-{index}.txt').write_bytes(content)
                    notices.append(f'\n{name}@{version} / {member.name}\n' + content.decode('utf-8', errors='replace'))
    for package in ['three', 'fflate', '@simonwep/pickr']:
        directory = ROOT / 'node_modules' / package
        for candidate in directory.iterdir():
            if candidate.is_file() and candidate.name.lower().startswith('license'):
                notices.append(f'\n{package}\n' + candidate.read_text(errors='replace'))
    shutil.copy2(ROOT / 'LICENSE.md', destination / 'LICENSE.md')
    (destination / 'THIRD_PARTY_NOTICES.txt').write_text('\n'.join(notices))
    native_license = ROOT / 'build/ios/opennurbs-src/LICENSE'
    if native_license.exists():
        (destination / 'OPENNURBS_LICENSE.txt').write_text(native_license.read_text())
    shutil.copy2(ROOT / 'ios/Online3DViewer/ThirdParty/ufbx/LICENSE', destination / 'UFBX_LICENSE.txt')
    shutil.copy2(ROOT / 'ios/Online3DViewer/ThirdParty/earcut/LICENSE', destination / 'EARCUT_LICENSE.txt')
    shutil.copy2(ROOT / 'ios/Online3DViewer/ThirdParty/cgltf/LICENSE', destination / 'CGLTF_LICENSE.txt')
    shutil.copy2(ROOT / 'ios/Online3DViewer/ThirdParty/draco/LICENSE', destination / 'DRACO_NATIVE_LICENSE.txt')
    shutil.copy2(ROOT / 'ios/Online3DViewer/ThirdParty/openskp/LICENSE', destination / 'OPENSKP_LICENSE.txt')
    shutil.copy2(ROOT / 'ios/Online3DViewer/ThirdParty/openskp/MINIZ_LICENSE', destination / 'OPENSKP_MINIZ_LICENSE.txt')
    shutil.copy2(ROOT / 'build/ios/acadrust-ios/LICENSE', destination / 'ACADRUST_LICENSE.txt')
    shutil.copy2(ROOT / 'build/ios/CAD_RUST_NOTICES.txt', destination / 'CAD_RUST_NOTICES.txt')
    shutil.copy2(ROOT / 'build/ios/acadrust-app-source.tar.gz', destination / 'acadrust-app-source.tar.gz')
    index = destination / 'index.html'
    html = index.read_text()
    html = html.replace('<head>', '<head>\n<script>window.O3DVNativeBridge = true;</script>\n'
                        '<style>#header > .title { display: none; } html, body { overscroll-behavior: none; }</style>')
    html = html.replace('</head>', '''<script>
function reportNativeError(error) {
    window.webkit?.messageHandlers?.o3dv?.postMessage({type: 'javascript_error', name: String(error)});
}
window.addEventListener('error', function (event) { reportNativeError(event.message || 'Resource loading failed'); });
window.addEventListener('unhandledrejection', function (event) { reportNativeError(event.reason); });
window.addEventListener('load', function () {
    document.getElementById('intro_dragdrop_text').textContent = '点击右上角文件夹，打开本地模型';
    document.getElementById('intro_formats_title').textContent = '或选择内置示例：';
});
</script>
</head>''')
    index.write_text(html)
    manifest = [{'name': name, 'version': version, 'directory': directory} for name, version, directory, _ in PACKAGES]
    (destination / 'offline-libraries.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'iOS resources prepared: {destination}', flush=True)


if __name__ == '__main__':
    main()
