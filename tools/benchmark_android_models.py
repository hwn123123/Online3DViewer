#!/usr/bin/env python3
"""Measure real local models on a connected Android device using an isolated debug library."""
import argparse
import json
import subprocess
import time
from pathlib import Path

PACKAGE = 'com.hwn.modelviewer'
ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--device', required=True)
    parser.add_argument('--adb', default='adb')
    parser.add_argument('--output', default=str(ROOT / 'build/android-tests/work-models'))
    parser.add_argument('models', nargs='+', type=Path)
    args = parser.parse_args()
    out = Path(args.output); out.mkdir(parents=True, exist_ok=True)
    adb = [args.adb, '-s', args.device]
    results = []

    def run(*values, binary=False, check=True, timeout=120):
        p = subprocess.run(adb + list(map(str, values)), stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=check, timeout=timeout)
        return p.stdout if binary else p.stdout.decode('utf-8', errors='replace')

    def status():
        try: return json.loads(run('shell', 'run-as', PACKAGE, 'cat', 'cache/viewer-debug-status.json', check=False))
        except (ValueError, OSError): return {}

    try:
        for index, path in enumerate(args.models, 1):
            path = path.resolve(); extension = path.suffix.lower().lstrip('.')
            if extension not in ('3dm', 'stl', 'obj', 'fbx') or not path.is_file():
                raise ValueError('Unsupported or missing test file: ' + str(path))
            fixture = {'3dm': 'fixture3dm', 'stl': 'fixture', 'obj': 'fixtureobj', 'fbx': 'fixturefbx'}[extension]
            remote = '/data/local/tmp/o3dv-work-test.' + extension
            cached = 'cache/android-test-fixture.' + extension
            case = {'source': str(path), 'bytes': path.stat().st_size, 'format': extension}
            print('TEST', path.name, '(%s bytes)' % case['bytes'], flush=True)
            run('shell', 'am', 'force-stop', PACKAGE)
            run('push', str(path), remote, timeout=300)
            try: run('shell', 'run-as', PACKAGE, 'cp', remote, cached, timeout=300)
            finally: run('shell', 'rm', '-f', remote, check=False)
            run('shell', 'run-as', PACKAGE, 'rm', '-f', 'cache/viewer-debug-status.json')
            flags = ['--ez', 'debug-library-test', 'true', '--es', 'debug-sample', fixture]
            if extension in ('3dm', 'stl'): flags += ['--ez', 'debug-benchmark', 'true']
            started = time.monotonic()
            run('shell', 'am', 'start', '-n', PACKAGE + '/.MainActivity', *flags)
            deadline = started + 240; loaded = None; benchmark = None; last = {}
            while time.monotonic() < deadline:
                last = status()
                if last.get('type') == 'model_loaded': loaded = last
                if last.get('type') == 'navigation_benchmark_complete': benchmark = last; break
                if last.get('type') in ('native_read_error', 'javascript_error', 'failed_to_load_file', 'import_failed'):
                    break
                if loaded and extension not in ('3dm', 'stl'): break
                time.sleep(.25)
            case['elapsedSeconds'] = round(time.monotonic() - started, 2)
            case['loaded'] = loaded
            case['benchmark'] = benchmark
            case['terminal'] = last
            if loaded or benchmark:
                run('shell', 'dumpsys', 'gfxinfo', PACKAGE, 'reset', check=False)
                before = run('exec-out', 'screencap', '-p', binary=True)
                for coords in ((300,1000,750,1000), (750,1000,300,1000), (500,1200,500,700)):
                    run('shell', "su -c 'input swipe %d %d %d %d 500'" % coords)
                    time.sleep(.4)
                time.sleep(1)
                after = run('exec-out', 'screencap', '-p', binary=True)
                (out / ('case-%02d-before.png' % index)).write_bytes(before)
                (out / ('case-%02d-after.png' % index)).write_bytes(after)
                try:
                    import io
                    from PIL import Image, ImageChops
                    first = Image.open(io.BytesIO(before)).convert('RGB')
                    second = Image.open(io.BytesIO(after)).convert('RGB')
                    w, h = first.size
                    area = (int(w * .08), int(h * .2), int(w * .92), int(h * .75))
                    case['modelAreaChanged'] = ImageChops.difference(first.crop(area), second.crop(area)).getbbox() is not None
                except ImportError:
                    case['modelAreaChanged'] = None
                gfx = run('shell', 'dumpsys', 'gfxinfo', PACKAGE, check=False)
                (out / ('case-%02d-gfxinfo.txt' % index)).write_text(gfx)
                print('  opened; benchmark:', [x.get('elapsedMs') for x in benchmark.get('results', [])] if benchmark else 'not available', 'model area changed:', case['modelAreaChanged'], flush=True)
            else:
                print('  NOT COMPLETE:', last.get('type'), last.get('message', ''), flush=True)
            results.append(case)
            (out / 'results.json').write_text(json.dumps(results, ensure_ascii=False, indent=2))
    finally:
        run('shell', 'am', 'force-stop', PACKAGE, check=False)
        for extension in ('3dm', 'stl', 'obj', 'fbx'):
            run('shell', 'run-as', PACKAGE, 'rm', '-f', 'cache/android-test-fixture.' + extension, check=False)
            run('shell', 'rm', '-f', '/data/local/tmp/o3dv-work-test.' + extension, check=False)
        run('shell', 'run-as', PACKAGE, 'rm', '-rf', 'files/model-library-test', check=False)
        run('shell', 'am', 'start', '-n', PACKAGE + '/.MainActivity', check=False)
    print('Results:', out / 'results.json', flush=True)

if __name__ == '__main__': main()
