#!/usr/bin/env python3
"""Smoke test local viewer assets and content URI import on a connected Android device."""
import argparse
from pathlib import Path
import subprocess
import time
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / 'build/android-tests'
PACKAGE = 'com.hwn.modelviewer'
REMOTE = '/sdcard/Download/o3dv-viewer-ui-test.xml'


def run(adb, *args, binary=False):
    result = subprocess.run([str(adb), *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True, timeout=20)
    return result.stdout if binary else result.stdout.decode('utf-8', errors='replace')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--adb', default='adb')
    parser.add_argument('--device', required=True)
    args = parser.parse_args()
    OUTPUT.mkdir(parents=True, exist_ok=True)
    serial = ('-s', args.device)
    try:
        for case in ('teapot', 'glb', '3dm', 'import'):
            run(args.adb, *serial, 'shell', 'am', 'force-stop', PACKAGE)
            run(args.adb, *serial, 'shell', 'am', 'start', '-n', PACKAGE + '/.MainActivity', '--es', 'debug-sample', case)
            deadline = time.monotonic() + 35
            seen = []
            while time.monotonic() < deadline:
                run(args.adb, *serial, 'shell', 'uiautomator', 'dump', REMOTE)
                xml = run(args.adb, *serial, 'shell', 'cat', REMOTE)
                root = ET.fromstring(xml)
                nodes = [n for n in root.iter('node') if n.get('package') == PACKAGE]
                seen = [n.get('text', '') for n in nodes if n.get('text')]
                if '模型已显示' in seen:
                    break
                if any(text in seen for text in ('无法打开模型', '打开失败，可重新选择文件')):
                    raise RuntimeError(f'{case}: {seen}')
                time.sleep(1)
            else:
                raise RuntimeError(f'{case}: timed out or viewer was not in foreground: {seen}')
            if case == 'import' and 'android-test-teapot.stl' not in seen:
                raise RuntimeError(f'{case}: content URI fixture name not displayed: {seen}')
            (OUTPUT / (case + '.png')).write_bytes(run(args.adb, *serial, 'exec-out', 'screencap', '-p', binary=True))
            print(f'PASS {case}: model displayed', flush=True)
    finally:
        subprocess.run([str(args.adb), *serial, 'shell', 'rm', '-f', REMOTE], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == '__main__':
    main()
