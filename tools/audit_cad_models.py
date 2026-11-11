#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Read-only DWG/DXF qualification; isolate and bound every decoder process."""
import argparse
import collections
import json
import os
import re
from pathlib import Path
import signal
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--inventory', type=Path, default=ROOT / 'build/ios/work-model-tests/inventory.json')
    parser.add_argument('--output', type=Path, default=ROOT / 'build/ios/dwg-dxf-tests/audit.json')
    parser.add_argument('--mode', choices=['strict', 'failsafe', 'sharded'], default='strict')
    parser.add_argument('--timeout', type=float, default=30)
    parser.add_argument('--rss-mib', type=int, default=768)
    parser.add_argument('--decompress-mib', type=int, default=256)
    parser.add_argument('--representative', action='store_true')
    args = parser.parse_args()
    args.output = args.output.resolve()
    sources = [entry for entry in json.loads(args.inventory.read_text()) if entry['format'] in ('dwg', 'dxf')]
    for entry in sources:
        with open(entry['path'], 'rb') as source:
            header = source.read(65536 if entry['format'] == 'dxf' else 6)
            if entry['format'] == 'dxf':
                version = re.search(rb'\$ACADVER[\s\S]{0,32}?(AC[0-9]{4})', header)
                entry['version'] = version[1].decode('ascii') if version else 'DXF-unknown'
            else:
                entry['version'] = header.decode('ascii', errors='replace')
    groups = collections.defaultdict(list)
    for entry in sources:
        groups[entry['version']].append(entry)
    if args.representative:
        sources = []
        for version, entries in sorted(groups.items()):
            entries.sort(key=lambda item: item['bytes'])
            indexes = {0, min(1, len(entries)-1), len(entries)//2, len(entries)-1}
            sources.extend(entries[index] for index in sorted(indexes))
    else:
        sources.sort(key=lambda entry: entry['bytes'])
    executable = ROOT / 'build/ios/cad-probe-target/release/o3dv-cad-probe'
    results = []
    args.output.parent.mkdir(parents=True, exist_ok=True)
    for number, entry in enumerate(sources):
        started, peak, stopped = time.monotonic(), 0, None
        before = Path(entry['path']).stat()
        log = args.output.parent / f'{args.output.stem}-{number:03d}.log'
        output = args.output.parent / f'{args.output.stem}-{number:03d}.json'
        with log.open('w') as stderr, output.open('w') as stdout:
            child = subprocess.Popen([str(executable), entry['path'], args.mode], stdout=stdout, stderr=stderr,
                                     env={**os.environ, 'O3DV_CAD_DECOMPRESS_LIMIT': str(args.decompress_mib*1024*1024)})
            while child.poll() is None:
                memory = subprocess.run(['ps', '-o', 'rss=', '-p', str(child.pid)], capture_output=True, text=True)
                try:
                    peak = max(peak, int(memory.stdout.strip())*1024)
                except ValueError:
                    pass
                if peak > args.rss_mib*1024*1024:
                    stopped = 'host-rss-guard'
                elif time.monotonic()-started > args.timeout:
                    stopped = 'host-timeout'
                if stopped:
                    child.send_signal(signal.SIGKILL)
                    break
                time.sleep(.1)
            code = child.wait()
        try:
            decoded = json.loads(output.read_text().strip().splitlines()[-1])
        except (ValueError, IndexError):
            decoded = {'error': stopped or f'process-exit-{code}', 'shards': []}
        peak = max(peak, decoded.get('peakResidentBytes') or 0)
        after = Path(entry['path']).stat()
        unchanged = (before.st_size,before.st_mtime_ns)==(after.st_size,after.st_mtime_ns)
        resource_exceeded = peak > args.rss_mib*1024*1024
        row = {**entry, 'exitCode': code, 'sampledPeakRSS': peak, 'elapsed': round(time.monotonic()-started, 3),
               'decoder': decoded, 'log': str(log.relative_to(ROOT)),
               'sourceUnchanged': unchanged, 'resourceLimitExceeded': resource_exceeded,
               'qualified': code==0 and not decoded.get('error') and unchanged and not resource_exceeded}
        results.append(row)
        temporary = args.output.with_suffix('.tmp')
        temporary.write_text(json.dumps({'mode': args.mode, 'total': len(sources), 'completed': len(results),
                                         'versionCounts': {key: len(value) for key, value in groups.items()},
                                         'limits': {'timeoutSeconds': args.timeout, 'rssGuardBytes': args.rss_mib*1024*1024,
                                                    'decompressBytes': args.decompress_mib*1024*1024, 'samplingSeconds': .1},
                                         'results': results}, ensure_ascii=False, indent=2))
        temporary.replace(args.output)
        inventories = decoded.get('shards', [])
        entities = sum(sum(shard['inventory']['allEntityTypes'].values()) for shard in inventories)
        print(f'{number+1}/{len(sources)} {entry["version"]} {entry["bytes"]//1024}KiB {row["elapsed"]}s '
              f'{peak//1048576}MiB {entities} entities '
              f'{decoded.get("error") or ("post-read-rss-limit" if resource_exceeded else "read-complete")}', flush=True)


if __name__ == '__main__':
    main()
