#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${MOX_BUILD_CONFIGURATION:-Release}"
case "$configuration" in Debug|Release) ;; *) echo 'Invalid build configuration' >&2; exit 2 ;; esac
# Fixtures participate in the same identity handshake as the real worker.
# Refresh them after an App rebuild so focused UI runs cannot use a stale identity.
swift build --scratch-path .build/m2-tests --product MoxTestSupport
# The app must be outside the UI Runner's sandbox container for launchd to execute it.
relocated_root=$(mktemp -d '/private/tmp/Mox M2 独立验收.XXXXXX')
trap '/bin/rm -rf "$relocated_root"' EXIT
/usr/bin/ditto ".build/m2/$configuration/Mox.app" "$relocated_root/本地聊天.app"
printf '%s' "$relocated_root/本地聊天.app" > .build/m2-relocated-app-path.txt
xcodebuild -project Mox.xcodeproj -scheme Mox -configuration "$configuration" \
  -derivedDataPath .build/m2-app -destination 'platform=macOS,arch=arm64' \
  -skipPackagePluginValidation "$@" test
