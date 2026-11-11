#!/usr/bin/env python3
"""Build the pinned, desktop-only DWG/DXF qualification tool."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
REVISION = '362561cd8b44bbb4bbf5cad5b95fb16eb976b93d'
RUST_VERSION = '1.99.1'
UPSTREAM = ROOT / 'build/ios/acadrust-upstream'


def run(arguments, **kwargs):
    return subprocess.run([str(value) for value in arguments], check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--check-ios', action='store_true', help='Check Rust code for arm64 iOS; does not build/install an app')
    parser.add_argument('--test', action='store_true')
    args = parser.parse_args()
    UPSTREAM.parent.mkdir(parents=True, exist_ok=True)
    if not UPSTREAM.exists():
        run(['git', 'init', UPSTREAM])
        run(['git', '-C', UPSTREAM, 'remote', 'add', 'origin', 'https://github.com/hakanaktt/acadrust.git'])
        run(['git', '-C', UPSTREAM, 'fetch', '--depth=1', 'origin', REVISION])
        run(['git', '-C', UPSTREAM, 'checkout', '--detach', REVISION])
    revision = subprocess.check_output(['git', '-C', str(UPSTREAM), 'rev-parse', 'HEAD'], text=True).strip()
    if revision != REVISION:
        raise SystemExit(f'Unexpected acadrust revision {revision}; expected {REVISION}')
    if subprocess.check_output(['git', '-C', str(UPSTREAM), 'status', '--porcelain'], text=True).strip():
        raise SystemExit('The qualification dependency has local changes; use the unmodified pinned source.')
    environment = dict(os.environ)
    local_rust = ROOT / 'build/ios/rust-tools'
    if (local_rust / 'cargo/bin/cargo').exists():
        environment.update(CARGO_HOME=str(local_rust / 'cargo'), RUSTUP_HOME=str(local_rust / 'rustup'))
        environment['PATH'] = str(local_rust / 'cargo/bin') + os.pathsep + environment['PATH']
    if not shutil.which('cargo', path=environment['PATH']):
        raise SystemExit(f'Install Rust {RUST_VERSION} using rustup first: https://rust-lang.org/tools/install/')
    rust = subprocess.check_output(['rustc', '--version'], env=environment, text=True).strip()
    if rust.split()[1] != RUST_VERSION:
        raise SystemExit(f'Qualification is pinned to Rust {RUST_VERSION}; current toolchain: {rust}')
    environment['CARGO_TARGET_DIR'] = str(ROOT / 'build/ios/cad-probe-target')
    manifest = ROOT / 'tools/cad_probe/Cargo.toml'
    command = ['cargo', 'build', '--release', '--locked', '--manifest-path', manifest]
    run(command, env=environment, cwd=ROOT)
    if args.test:
        run(['cargo', 'test', '--release', '--locked', '--manifest-path', manifest], env=environment, cwd=ROOT)
    if args.check_ios:
        run(['cargo', 'check', '--release', '--locked', '--target', 'aarch64-apple-ios', '--manifest-path', manifest], env=environment, cwd=ROOT)
    executable = ROOT / 'build/ios/cad-probe-target/release/o3dv-cad-probe'
    metadata = {'acadrustRevision': revision, 'acadrustLicense': 'MPL-2.0', 'rust': rust,
                'iosTypeCheck': args.check_ios, 'tests': args.test,
                'lockSHA256': hashlib.sha256((manifest.parent / 'Cargo.lock').read_bytes()).hexdigest(),
                'sourceSHA256': hashlib.sha256((manifest.parent / 'src/main.rs').read_bytes()).hexdigest(),
                'executableSHA256': hashlib.sha256(executable.read_bytes()).hexdigest()}
    target = ROOT / 'build/ios/dwg-dxf-tests/build-metadata.json'
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(metadata, indent=2) + '\n')
    print(executable)


if __name__ == '__main__':
    main()
