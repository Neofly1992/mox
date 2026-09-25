#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export MOX_BUILD_MILESTONE=m3
scripts/build-m3.sh Debug > .build/m3-ui-build.log 2>&1
xcodebuild -project Mox.xcodeproj -scheme Mox -configuration Debug \
  -derivedDataPath .build/m3-app -destination 'platform=macOS,arch=arm64' \
  -skipPackagePluginValidation -only-testing:MoxUITests/MoxUITests/testM3AcquireInstallAndChat \
  -only-testing:MoxUITests/MoxUITests/testM3ConfiguredMirrorSurvivesAcquireSheet \
  MOX_BUILD_MILESTONE=m3 test
