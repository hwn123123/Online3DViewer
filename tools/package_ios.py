#!/usr/bin/env python3
"""Package the signed device build as a development IPA."""
from pathlib import Path
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / 'build' / 'ios'


def main():
    app = OUTPUT / 'DerivedData' / 'Build' / 'Products' / 'Debug-iphoneos' / 'Online3DViewer.app'
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    if not (app / 'embedded.mobileprovision').exists():
        raise SystemExit('The device app is not provisioned. Select a development team and rebuild first.')
    payload = OUTPUT / 'Payload'
    if payload.exists():
        shutil.rmtree(payload)
    payload.mkdir()
    shutil.copytree(app, payload / app.name, symlinks=True)
    ipa = OUTPUT / 'Online3DViewer.ipa'
    ipa.unlink(missing_ok=True)
    subprocess.run(['ditto', '-c', '-k', '--keepParent', str(payload), str(ipa)], check=True)
    decoded = subprocess.check_output(['security', 'cms', '-D', '-i', str(app / 'embedded.mobileprovision')], stderr=subprocess.DEVNULL)
    profile = plistlib.loads(decoded)
    print(f'Development IPA: {ipa}')
    print(f'Size: {ipa.stat().st_size / 1024 / 1024:.1f} MiB')
    print(f'Profile expires (UTC): {profile["ExpirationDate"].isoformat()}')
    print(f'Provisioned devices: {len(profile.get("ProvisionedDevices", []))}')


if __name__ == '__main__':
    main()
