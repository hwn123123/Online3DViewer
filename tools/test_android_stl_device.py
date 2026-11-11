#!/usr/bin/env python3
"""Check Android STL stream output independently against source faces on a device."""
import argparse
import json
import shutil
import subprocess
import tarfile
import time
from pathlib import Path
from urllib.parse import urlparse

from test_stl_stream import binary, source_faces, cache_faces, statistics

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'build/android-tests/stl-stream'
PACKAGE = 'com.hwn.modelviewer'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--adb', default='adb')
    parser.add_argument('--device', required=True)
    args = parser.parse_args()
    adb = [args.adb, '-s', args.device]
    OUT.mkdir(parents=True, exist_ok=True)

    def cmd(*values, check=True, timeout=60):
        return subprocess.run([*adb, *map(str, values)], capture_output=True, text=True, check=check, timeout=timeout)

    def stage(source):
        cmd('shell', 'am', 'force-stop', PACKAGE)
        cmd('shell', 'run-as', PACKAGE, 'rm', '-f', 'cache/android-test-fixture.stl')
        cmd('shell', 'run-as', PACKAGE, 'rm', '-f', 'cache/viewer-debug-status.json')
        cmd('push', source, '/data/local/tmp/o3dv-android-test-fixture.stl', timeout=120)
        try:
            cmd('shell', 'run-as', PACKAGE, 'cp', '/data/local/tmp/o3dv-android-test-fixture.stl', 'cache/android-test-fixture.stl', timeout=120)
        finally:
            cmd('shell', 'rm', '-f', '/data/local/tmp/o3dv-android-test-fixture.stl', check=False)

    def start(budget):
        cmd('shell', 'am', 'start', '-n', PACKAGE + '/.MainActivity', '--es', 'debug-sample', 'fixture', '--ei', 'debug-budget', str(budget))

    def status():
        result = cmd('shell', 'run-as', PACKAGE, 'cat', 'cache/viewer-debug-status.json', check=False)
        try:
            return json.loads(result.stdout)
        except ValueError:
            return {}

    def await_terminal(timeout=120):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            state = status()
            if state.get('type') in ('model_loaded', 'javascript_error', 'native_read_error'):
                return state
            time.sleep(.5)
        raise RuntimeError('model timed out: ' + repr(status()))

    def check_case(name, source, budget):
        stage(source)
        start(budget)
        state = await_terminal()
        assert state.get('type') == 'model_loaded', (name, state)
        assert state.get('reader') == 'stl-stream-1' and state.get('complete') and state.get('gpuComplete'), (name, state)
        assert state.get('peakWorkingBytes', 0) <= budget, (name, state)
        url = urlparse(state['manifestUrl'])
        components = url.path.split('/')
        assert components[1] == 'imports' and len(components) == 5 and components[3] == 'stream'
        ident = components[2]
        assert len(ident) == 36 and all(c in '0123456789abcdef-' for c in ident), ident
        target = OUT / name
        shutil.rmtree(target, ignore_errors=True)
        target.mkdir()
        archive = target / 'stream.tar'
        with archive.open('wb') as output:
            subprocess.run([*adb, 'exec-out', 'run-as', PACKAGE, 'tar', '-C', 'cache/viewer-imports/' + ident, '-cf', '-', 'stream'], stdout=output, check=True, timeout=60)
        with tarfile.open(archive) as data:
            for member in data.getmembers():
                assert member.name == 'stream' or member.name.startswith('stream/'), member.name
                assert '..' not in Path(member.name).parts and not member.issym() and not member.islnk(), member.name
            data.extractall(target)
        archive.unlink()
        expected = statistics(source_faces(source))
        actual = statistics(cache_faces(target / 'stream'))
        assert actual['orderedFaceSHA256'] == expected['orderedFaceSHA256'], (name, actual, expected)
        assert actual['triangles'] == expected['triangles'] == state['triangles'], (name, actual, expected, state)
        if budget == 262144:
            assert state['frameReadRequests'] > state['objectCount'], (name, state)
        (target / 'result.json').write_text(json.dumps({'state': state, 'expected': expected, 'actual': actual}, indent=2))
        print(f"PASS {name}: {actual['triangles']} faces, matching geometry, budget {budget}", flush=True)

    try:
        source = OUT / 'binary-multiblock.stl'
        binary(source, 32769)
        check_case('binary-multiblock', source, 262144)
        ascii_source = OUT / 'ascii-multiple.stl'
        ascii_source.write_text('''solid first\nfacet normal 0 0 0\nouter loop\nvertex 0 0 0\nvertex 1 0 0\nvertex 0 1 0\nendloop\nendfacet\nendsolid first\nsolid second\nfacet normal 0 0 1\nouter loop\nvertex 0 0 2\nvertex 0 1 2\nvertex 1 0 2\nendloop\nendfacet\nendsolid second\n''')
        check_case('ascii-multiple', ascii_source, 8 * 1024 * 1024)
        broken = OUT / 'broken.stl'
        with source.open('rb') as inp, broken.open('wb') as out:
            out.write(inp.read(200))
        stage(broken)
        start(8 * 1024 * 1024)
        failure = await_terminal()
        assert failure.get('type') == 'native_read_error', failure
        print('PASS truncated binary: reported native read error', flush=True)
    finally:
        cmd('shell', 'run-as', PACKAGE, 'rm', '-f', 'cache/android-test-fixture.stl', check=False)
        cmd('shell', 'rm', '-f', '/data/local/tmp/o3dv-android-test-fixture.stl', check=False)


if __name__ == '__main__':
    main()
