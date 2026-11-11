#!/bin/zsh
set -euo pipefail
O3DV_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
O3DV_LOCAL_NODE="$O3DV_ROOT/../.tools/node-v22.23.4-darwin-arm64/bin"
if [[ -d "$O3DV_LOCAL_NODE" ]]; then
    export PATH="$O3DV_LOCAL_NODE:$PATH"
fi
cd "$O3DV_ROOT"
if [[ ! -x node_modules/.bin/esbuild ]]; then
    npm ci --no-audit --no-fund
fi
npm run create_dist
python3 tools/build_opennurbs.py
python3 tools/build_draco.py
python3 tools/build_openskp.py
python3 tools/build_cad_reader.py --ios
python3 tools/prepare_ios.py
python3 ios/generate_project.py
O3DV_SIGNING_OPTIONS=()
if [[ -n "${O3DV_TEAM_ID:-}" ]]; then
    O3DV_SIGNING_OPTIONS+=("DEVELOPMENT_TEAM=$O3DV_TEAM_ID")
fi
xcodebuild -project ios/Online3DViewer.xcodeproj -scheme Online3DViewer \
    -configuration Debug -destination 'generic/platform=iOS' \
    -derivedDataPath build/ios/DerivedData -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration "${O3DV_SIGNING_OPTIONS[@]}" build
python3 tools/package_ios.py
