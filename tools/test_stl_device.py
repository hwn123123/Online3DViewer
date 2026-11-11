#!/usr/bin/env python3
"""Exercise actual native STL loading, bounded display and recovery on an iPhone."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import time
import uuid

import audit_work_models as audit

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT/'build/ios/stl-stream-tests/device'
SOURCES = ROOT/'build/ios/stl-stream-tests/sources'
DOMAIN = audit.DOMAIN
CASE_PREFIX = '44444444-4444-4444-8444-'


def stage(number, source, **settings):
    ident = CASE_PREFIX+f'{number:012d}'
    directory = OUTPUT/'fixtures'/ident
    files = directory/'files';files.mkdir(parents=True, exist_ok=True)
    target = files/source.name
    if not target.exists():
        result = subprocess.run(['cp', '-c', str(source), str(target)], capture_output=True)
        if result.returncode:shutil.copyfile(source, target)
    companions = settings.pop('companions', [])
    for relative in companions:
        original = source.parent/relative
        destination = files/relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        if not destination.exists():
            result = subprocess.run(['cp', '-c', str(original), str(destination)], capture_output=True)
            if result.returncode:shutil.copyfile(original, destination)
    config = {'files': [source.name, *companions], **settings}
    (directory/'case.json').write_text(json.dumps(config))
    return ident, directory


def status(args, remote, run):
    result = audit.read_status(args, 'Library/Caches/'+remote, OUTPUT/('live-'+remote))
    return result if result and result.get('testRun') == run else None


def run_case(args, number, source, expected='model_loaded', triangles=None, budget=8*1048576, **settings):
    ident, fixture = stage(number, source, memoryPolicy={'geometryBytes': budget}, **settings)
    audit.device(args, 'copy', 'to', *DOMAIN, '--source', str(fixture), '--destination',
                 'Library/Caches/ModelImports/FormatAudit/'+ident, timeout=120)
    run = '--test-run=stl-device-'+str(uuid.uuid4())
    audit.launch(args, ['--audit-case='+ident, '--benchmark-navigation', run])
    started = time.monotonic();first = benchmark = None
    while time.monotonic()-started < args.timeout:
        current = status(args, 'format-audit-status.json', run)
        if current and current['event'] in audit.TERMINAL | {'load_cancelled'}:
            first = current
            if current['event'] != 'model_loaded':break
        if first and first['event'] == 'model_loaded':
            if not first['details'].get('stream'):
                break
            benchmark = status(args, 'navigation-benchmark.json', run)
            if benchmark:break
        time.sleep(.5)
    assert first and first['event'] == expected, (source.name, expected, first)
    if expected == 'model_loaded':
        details = first['details']
        if details.get('stream'):
            assert benchmark and benchmark['event'] == 'navigation_benchmark_complete', (source, benchmark)
        if source.suffix.lower() == '.stl':
            assert details['reader'] == 'stl-stream-1' and details['unsupportedCount'] == 0
            assert details['displayed'] == details['objectCount'] and details['triangles'] == triangles
        if source.suffix.lower() in {'.gltf', '.glb'}:
            assert details.get('reader') == 'gltf-stream-1', details
            assert details['displayed'] == details['objectCount'] and details['unsupportedCount'] == 0
            if triangles is not None:assert details['triangles'] == triangles, details
        for frame in [details]+(benchmark['details']['results'] if benchmark else []):
            assert frame.get('peakWorkingBytes', 0) <= frame.get('peakWorkingBudgetBytes', budget), frame
            assert frame.get('residentPeakBytes', 0) <= frame.get('geometryBudgetBytes', budget), frame
    else:
        # Failure/cancellation must stay stopped; a stale WebView must not emit later loading events.
        time.sleep(2)
        current = status(args, 'viewer-status.json', run)
        assert current and (current['event'] == expected or
                            (current['event'] == 'ready' and current['details'].get('libraryID') == '')), current
        terminal = status(args, 'format-audit-status.json', run)
        assert terminal and terminal['event'] == expected, terminal
        listing = audit.device(args, 'info', 'files', *DOMAIN, '--subdirectory',
                               'Library/Caches/ModelImports', '--no-recurse')
        if ident in listing.stdout:
            # The per-model parent may remain empty after removing the unfinished stream directory.
            tree = OUTPUT/'stopped-cache-tree.json'
            audit.device(args, 'info', 'files', *DOMAIN, '--subdirectory',
                         'Library/Caches/ModelImports/'+ident, '--recurse', '--json-output', str(tree))
            assert not json.loads(tree.read_text())['result']['files'], ('incomplete native cache was not removed', ident)
    screenshot = OUTPUT/f'{number:02d}-{source.stem}.png'
    audit.device(args, 'capture', 'screenshot', '--destination', str(screenshot), timeout=20)
    row = {'number': number, 'source': str(source), 'seconds': round(time.monotonic()-started, 2),
           'state': first, 'navigation': benchmark, 'screenshot': str(screenshot.relative_to(ROOT))}
    if number == 1:
        # Reopen the actual phone-generated cache, without invoking the STL reader again.
        listing_file = OUTPUT/'cache-list.json'
        audit.device(args, 'info', 'files', *DOMAIN, '--subdirectory', 'Library/Caches/ModelImports/'+ident,
                     '--no-recurse', '--json-output', str(listing_file))
        listing = json.loads(listing_file.read_text())
        entries = listing['result']['files']
        names = [item['name'] for item in entries if item['name'].startswith('stream-')]
        assert len(names) == 1, listing
        config = json.loads((fixture/'case.json').read_text());config['preparedCache'] = names[0]
        (fixture/'case.json').write_text(json.dumps(config))
        audit.device(args, 'copy', 'to', *DOMAIN, '--source', str(fixture), '--destination',
                     'Library/Caches/ModelImports/FormatAudit/'+ident)
        repeat = '--test-run=stl-cached-'+str(uuid.uuid4())
        audit.launch(args, ['--audit-case='+ident, '--benchmark-navigation', repeat])
        for _ in range(60):
            reopened = status(args, 'format-audit-status.json', repeat)
            if reopened and reopened['event'] in audit.TERMINAL:break
            time.sleep(.5)
        assert reopened['event'] == 'model_loaded' and reopened['details']['triangles'] == first['details']['triangles'], reopened
        row['cachedReopen'] = reopened
    audit.OUTPUT = OUTPUT
    audit.clean(args, {'id': ident})
    print('PASS', number, source.name, expected, row['seconds'], flush=True)
    return row


def main():
    parser = argparse.ArgumentParser();parser.add_argument('--device', required=True)
    parser.add_argument('--timeout', type=int, default=180);parser.add_argument('--only', type=int, nargs='+')
    parser.add_argument('--work-stl', type=Path, help='Optional local STL sample to test')
    parser.add_argument('--work-triangles', type=int, default=720)
    args = parser.parse_args();OUTPUT.mkdir(parents=True, exist_ok=True)
    # Damage is confined to a generated source; the work file is read only.
    damaged = SOURCES/'late-corrupt-ascii.stl'
    if not damaged.exists():
        shutil.copyfile(SOURCES/'large-ascii.stl', damaged)
        with damaged.open('r+b') as handle:handle.truncate(damaged.stat().st_size-len('endsolid grid\n'))
    cases = [
        (2, ROOT/'test/testfiles/stl/cube_meshlab_ascii.stl', 'model_loaded', 12, 262144, {}),
        (3, ROOT/'build/ios/WebAssets/assets/models/utah_teapot.stl', 'model_loaded', 9438, 262144, {}),
        (4, SOURCES/'large-binary.stl', 'model_loaded', 1048576, 8*1048576, {}),
        (5, SOURCES/'large-ascii.stl', 'model_loaded', 262144, 2*1048576, {}),
        (6, SOURCES/'truncated-binary.stl', 'native_read_error', None, 8*1048576, {}),
        (7, damaged, 'native_read_error', None, 2*1048576, {}),
        (8, SOURCES/'large-ascii.stl', 'load_cancelled', None, 2*1048576, {'cancelAfterReadBytes': 1}),
        # Same source after cancellation, through a fresh native load.
        (9, SOURCES/'large-ascii.stl', 'model_loaded', 262144, 2*1048576, {}),
        (10, ROOT/'build/ios/WebAssets/assets/models/DamagedHelmet.glb', 'model_loaded', None, 8*1048576, {}),
        (11, ROOT/'build/ios/WebAssets/assets/models/RhinoLogo.3dm', 'model_loaded', None, 8*1048576, {}),
    ]
    if args.work_stl: cases.insert(0, (1, args.work_stl, 'model_loaded', args.work_triangles, 8*1048576, {}))
    output = OUTPUT/'results.json';results = json.loads(output.read_text()) if output.exists() else []
    for number, source, expected, triangles, budget, settings in cases:
        if args.only and number not in args.only:continue
        row = run_case(args, number, source, expected, triangles, budget, **settings)
        results = [r for r in results if r['number'] != number]+[row]
        output.write_text(json.dumps(sorted(results, key=lambda r: r['number']), ensure_ascii=False, indent=2)+'\n')


if __name__ == '__main__':
    main()
