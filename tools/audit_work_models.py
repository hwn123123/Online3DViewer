#!/usr/bin/env python3
"""Run isolated local-model fixtures through the actual installed iOS app."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / 'build/ios/work-model-tests'
DOMAIN = ['--domain-type', 'appDataContainer', '--domain-identifier', 'com.hwn.Online3DViewer']
TERMINAL = {'model_loaded', 'javascript_error', 'native_read_error', 'webcontent_terminated', 'resource_limit',
            'no_importable_file', 'failed_to_load_file', 'import_failed'}
BACKUPS = {'3dmbak': '3dm', '3dsbak': '3ds', 'skpbak': 'skp'}
IMAGES = {'jpg', 'jpeg', 'png', 'bmp', 'tga', 'tif', 'tiff', 'webp', 'dds', 'mtl', 'hdr', 'exr'}


def write_json(path, value):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
    temporary.replace(path)


def prepare():
    inventory = json.loads((OUTPUT / 'inventory.json').read_text())
    capabilities = json.loads((OUTPUT / 'importer-capabilities.json').read_text())
    known = {r['path'] for r in inventory}
    for raw in (ROOT / 'build/ios/work-files.list0').read_bytes().split(b'\0'):
        if not raw:
            continue
        p = Path(os.fsdecode(raw))
        if p.suffix.lower().lstrip('.') in BACKUPS and str(p) not in known:
            inventory.append({'path': str(p), 'relative': str(p.relative_to(Path.home() / '工作')),
                              'format': p.suffix.lower()[1:], 'bytes': p.stat().st_size, 'category': 'backup'})
    cases, unsupported = [], []
    for row in inventory:
        if row.get('category') not in {'model', 'backup', 'drawing'}:
            continue
        row['source_mtime_ns'] = Path(row['path']).stat().st_mtime_ns
        with Path(row['path']).open('rb') as source:
            row['header_hex'] = source.read(32).hex()
        ext = row['format']
        alias = BACKUPS.get(ext, ext)
        if capabilities.get(alias, False):
            cases.append({**row, 'reader_format': alias, 'test_kind': 'backup_alias' if alias != ext else 'model'})
        else:
            unsupported.append({**row, 'status': 'unsupported_no_importer',
                                'reason': f'当前导入器未注册 .{ext}，未将大文件复制到手机逐个解析。'})
    # One real negative control per unsupported primary format verifies the app's failure path.
    for ext in ['max', 'skp', 'dwg']:
        candidates = [r for r in unsupported if r['format'] == ext]
        if candidates:
            cases.append({**min(candidates, key=lambda r: r['bytes']), 'reader_format': ext, 'test_kind': 'unsupported_probe'})
    cases.sort(key=lambda c: (c['test_kind'] == 'unsupported_probe', c['bytes']))
    for i, case in enumerate(cases):
        case['number'] = i + 1
        case['id'] = str(uuid.uuid5(uuid.NAMESPACE_URL, 'o3dv-work-audit:' + case['path'])).upper()
    write_json(OUTPUT / 'inventory.json', inventory)
    write_json(OUTPUT / 'cases.json', cases)
    write_json(OUTPUT / 'unsupported.json', unsupported)
    print(f'Prepared {len(cases)} device cases; {len(unsupported)} files have no importer.', flush=True)


def stage(case):
    directory = OUTPUT / 'fixtures' / case['id']
    if directory.exists():
        return directory
    source = Path(case['path'])
    files = directory / 'files'
    files.mkdir(parents=True)
    primary = source.name
    if case['test_kind'] == 'backup_alias':
        primary = source.stem + '.' + case['reader_format']
    members = [(source, Path(primary))]
    # Keep companion files next to the model and in nearby texture folders.
    for p in source.parent.rglob('*'):
        if not p.is_file() or p.suffix.lower()[1:] not in IMAGES:
            continue
        relative = p.relative_to(source.parent)
        if len(relative.parts) <= 3:
            members.append((p, relative))
    for original, relative in members:
        target = files / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        # APFS copy-on-write clone; the original inode and its contents stay untouched.
        result = subprocess.run(['cp', '-c', str(original), str(target)], capture_output=True)
        if result.returncode:
            shutil.copy2(original, target)
        if hasattr(os, 'chflags'):
            # Some work files are Finder-locked. Clear the flag on our clone only.
            assert target.stat().st_ino != original.stat().st_ino
            os.chflags(target, target.stat().st_flags & ~stat.UF_IMMUTABLE)
    write_json(directory / 'case.json', {'files': [str(relative) for _, relative in members]})
    return directory


def device(args, *command, timeout=60):
    result = subprocess.run(['xcrun', 'devicectl', 'device', *command, '--device', args.device],
                            capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError((result.stderr or result.stdout)[-2500:])
    return result


def launch(args, arguments):
    for attempt in range(3):
        result = subprocess.run(['xcrun', 'devicectl', 'device', 'process', 'launch', '--device', args.device,
                                 '--terminate-existing', 'com.hwn.Online3DViewer', '--', *arguments],
                                capture_output=True, text=True, timeout=45)
        if not result.returncode:
            return
        message = (result.stderr or result.stdout)[-2500:]
        if '10004' not in message:
            raise RuntimeError(message)
        time.sleep(1)
    raise RuntimeError(message)


def read_status(args, remote, local):
    local.unlink(missing_ok=True)
    try:
        result = subprocess.run(['xcrun', 'devicectl', 'device', 'copy', 'from', '--device', args.device,
                                 *DOMAIN, '--source', remote, '--destination', str(local)], capture_output=True, timeout=20)
    except subprocess.TimeoutExpired:
        return None
    if result.returncode or not local.exists():
        return None
    try:
        return json.loads(local.read_text())
    except (OSError, ValueError):
        return None


def clean(args, case):
    run = '--test-run=cleanup-' + str(uuid.uuid4())
    launch(args, ['--audit-clean=' + case['id'], run])
    for _ in range(40):
        state = read_status(args, 'Library/Caches/format-audit-clean.json', OUTPUT / 'cleanup-status.json')
        if state and state.get('testRun') == run:
            if state.get('event') != 'audit_cleaned':
                raise RuntimeError(state)
            return
        time.sleep(.25)
    raise RuntimeError('Timed out cleaning the isolated audit fixture')


def run_case(args, case):
    local = stage(case)
    name = case['relative']
    print(f"[{case['number']}] {name} ({case['bytes'] / 1048576:.2f} MiB)", flush=True)
    device(args, 'copy', 'to', *DOMAIN, '--source', str(local),
           '--destination', 'Library/Caches/ModelImports/FormatAudit/' + case['id'],
           '--json-output', str(OUTPUT / ('transfer-' + case['id'] + '.json')), timeout=240)
    run = '--test-run=work-audit-' + str(uuid.uuid4())
    start = time.monotonic()
    launch(args, ['--audit-case=' + case['id'], run])
    state, terminal_at = {}, None
    limit = args.timeout
    while time.monotonic() - start < limit:
        fresh = read_status(args, 'Library/Caches/format-audit-status.json', OUTPUT / (case['id'] + '-status.json'))
        if fresh and fresh.get('testRun') == run:
            state = fresh
            if state.get('event') in TERMINAL:
                if terminal_at is None:
                    terminal_at = time.monotonic()
                if state['event'] != 'model_loaded' or time.monotonic() - terminal_at >= 2:
                    break
        time.sleep(.6)
    elapsed = round(time.monotonic() - start, 2)
    details = state.get('details', {})
    if state.get('event') == 'model_loaded':
        if details.get('unsupportedCount', 0) > 0:
            outcome = 'partial_geometry'
        elif details.get('triangles', 0) == 0 and details.get('lineSegments', 0) == 0:
            outcome = 'no_visible_geometry'
        elif details.get('missingFiles'):
            outcome = 'loaded_missing_files'
        else:
            outcome = 'loaded'
    elif state.get('event') in TERMINAL:
        outcome = state['event']
    else:
        outcome = 'timeout'
    screenshot = OUTPUT / 'screenshots' / (f"{case['number']:02d}-" + case['id'] + '.png')
    screenshot.parent.mkdir(exist_ok=True)
    try:
        device(args, 'capture', 'screenshot', '--destination', str(screenshot), timeout=20)
    except Exception as e:
        screenshot = None
        print('Screenshot:', e, flush=True)
    result = {**case, 'status': outcome, 'seconds': elapsed, 'state': state,
              'screenshot': str(screenshot.relative_to(ROOT)) if screenshot else None,
              'source_unchanged': Path(case['path']).stat().st_size == case['bytes'] and
                                  Path(case['path']).stat().st_mtime_ns == case['source_mtime_ns']}
    print(json.dumps({'number': case['number'], 'file': name, 'status': outcome, 'seconds': elapsed,
                      'objects': details.get('objectCount'), 'triangles': details.get('triangles'),
                      'unsupported': details.get('unsupportedCount'), 'missing_files': details.get('missingFiles')}, ensure_ascii=False), flush=True)
    return result


def main():
    global OUTPUT
    parser = argparse.ArgumentParser()
    parser.add_argument('--prepare', action='store_true')
    parser.add_argument('--device')
    parser.add_argument('--limit', type=int)
    parser.add_argument('--timeout', type=int, default=150)
    parser.add_argument('--only', type=int, nargs='+')
    parser.add_argument('--retry', action='store_true')
    parser.add_argument('--output', type=Path, help='Separate result directory (must contain cases.json)')
    args = parser.parse_args()
    if args.output:
        OUTPUT = args.output.resolve()
    if args.prepare:
        prepare()
    if not args.device:
        return
    cases = json.loads((OUTPUT / 'cases.json').read_text())
    path = OUTPUT / 'device-results.json'
    results = json.loads(path.read_text()) if path.exists() else []
    completed = {r['id'] for r in results}
    selected = [c for c in cases if (args.retry or c['id'] not in completed) and (not args.only or c['number'] in args.only)]
    if args.limit:
        selected = selected[:args.limit]
    for case in selected:
        result = run_case(args, case)
        results = [r for r in results if r['id'] != case['id']] + [result]
        write_json(path, sorted(results, key=lambda r: r['number']))
        clean(args, case)
        print('Temporary device files cleaned.', flush=True)


if __name__ == '__main__':
    main()
