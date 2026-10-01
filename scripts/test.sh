#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mode="${1:-rules}"
if [[ $# -gt 0 ]]; then shift; fi
case "$mode" in rules|mlx|ui) ;; *) echo 'Usage: scripts/test.sh rules|mlx|ui [Xcode test options]' >&2; exit 2 ;; esac
scripts/check-toolchain.sh
python3 scripts/prepare-build.py
xcodebuild -resolvePackageDependencies -workspace .build/Mox.xcworkspace -scheme MoxCoreTests -derivedDataPath .build/package -skipPackagePluginValidation -onlyUsePackageVersionsFromResolvedFile
python3 scripts/stamp-build.py
common=(-configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/package -skipPackagePluginValidation -onlyUsePackageVersionsFromResolvedFile ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO)
case "$mode" in
rules)
  for scheme in MoxCoreTests MoxServiceTests MoxSourcesTests; do
    xcodebuild test -workspace .build/Mox.xcworkspace -scheme "$scheme" "${common[@]}" "$@"
  done ;;
mlx)
  : "${MOX_TEST_MODEL:?Set MOX_TEST_MODEL to an existing local model directory.}"
  scripts/check-toolchain.sh metal
  xcodebuild test -workspace .build/Mox.xcworkspace -scheme MoxMLXTests "${common[@]}" "$@" ;;
ui)
  configuration="${MOX_BUILD_CONFIGURATION:-Release}"
  [[ "$configuration" == Release || "$configuration" == Debug ]] || exit 2
  [[ -d ".build/$configuration/Mox.app" ]] || { echo 'Run scripts/build.sh first.' >&2; exit 1; }
  xcodebuild build -workspace .build/Mox.xcworkspace -scheme MoxTestSupport "${common[@]}"
  relocated_root=$(mktemp -d '/private/tmp/Mox UI.XXXXXX')
  trap 'rm -rf "$relocated_root"' EXIT
  ditto ".build/$configuration/Mox.app" "$relocated_root/本地聊天.app"
  printf '%s' "$relocated_root/本地聊天.app" > .build/relocated-app-path.txt
  xcodebuild test -project Mox.xcodeproj -scheme Mox -configuration "$configuration" -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/app -skipPackagePluginValidation -onlyUsePackageVersionsFromResolvedFile ARCHS=arm64 ONLY_ACTIVE_ARCH=YES "$@" ;;
esac
