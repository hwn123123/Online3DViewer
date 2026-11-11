#!/usr/bin/env python3
"""Build a pinned openNURBS static library for the native incremental reader."""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
REVISION = 'eb92af3ba1806b0a34a99aba0d3bda83e3d46083'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--platform', choices=['iphoneos', 'macosx'], default='iphoneos')
    parser.add_argument('--jobs', type=int, default=4)
    args = parser.parse_args()
    source = ROOT / 'build/ios/opennurbs-src'
    if not source.exists():
        subprocess.run(['git', '-c', 'http.version=HTTP/1.1', 'clone', '--no-checkout',
                        'https://github.com/mcneel/opennurbs.git', str(source)], check=True)
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=source, text=True).strip()
    if revision != REVISION:
        subprocess.run(['git', '-c', 'http.version=HTTP/1.1', 'fetch', '--depth', '1', 'origin', REVISION], cwd=source, check=True)
        subprocess.run(['git', 'checkout', '--detach', REVISION], cwd=source, check=True)
    cmake = shutil.which('cmake')
    if cmake is None:
        tools = ROOT / 'build/ios/native-tools'
        if not (tools / 'bin/python').exists():
            subprocess.run([sys.executable, '-m', 'venv', str(tools)], check=True)
        subprocess.run([str(tools / 'bin/python'), '-m', 'pip', 'install', '--disable-pip-version-check', 'cmake==3.31.6'], check=True)
        cmake = str(tools / 'bin/cmake')
    output = ROOT / 'build/ios' / ('opennurbs-' + args.platform)
    sdk = subprocess.check_output(['xcrun', '--sdk', args.platform, '--show-sdk-path'], text=True).strip()
    command = [cmake, '-S', str(source), '-B', str(output), '-G', 'Unix Makefiles',
               '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_OSX_ARCHITECTURES=arm64',
               '-DCMAKE_OSX_SYSROOT=' + sdk, '-DCMAKE_POSITION_INDEPENDENT_CODE=ON',
               '-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY', '-DBUILD_TESTING=OFF']
    if args.platform == 'iphoneos':
        command += ['-DCMAKE_SYSTEM_NAME=iOS', '-DCMAKE_OSX_DEPLOYMENT_TARGET=17.0']
    else:
        command += ['-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0']
    subprocess.run(command, check=True)
    subprocess.run([cmake, '--build', str(output), '--target', 'opennurbsStatic', '--parallel', str(args.jobs)], check=True)
    print(f'openNURBS {REVISION} / {args.platform}: {output}', flush=True)


if __name__ == '__main__':
    main()
