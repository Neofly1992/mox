#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-Release}"
case "$configuration" in
  Debug) debug_information=dwarf ;;
  Release) debug_information=dwarf-with-dsym ;;
  *) echo 'Usage: scripts/build.sh [Debug|Release]' >&2; exit 2 ;;
esac
if [[ $# -gt 1 ]]; then echo 'Expected one build configuration.' >&2; exit 2; fi
scripts/check-toolchain.sh metal
python3 scripts/prepare-build.py
# SwiftPM may normalize Package.resolved on a fresh checkout. Resolve first so the
# worker identity covers the exact lockfile that the App embed phase will check.
xcodebuild -resolvePackageDependencies -workspace ".build/Mox.xcworkspace" \
  -scheme mox -derivedDataPath .build/package -skipPackagePluginValidation
python3 scripts/stamp-build.py
xcodebuild -workspace ".build/Mox.xcworkspace" -scheme mox -configuration "$configuration" \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/package \
  -skipPackagePluginValidation ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO DEBUG_INFORMATION_FORMAT="$debug_information" build
products="$PWD/.build/package/Build/Products/$configuration"
worker="$PWD/.build/$configuration"
# Staging directories are generated outputs. Never merge obsolete bundles into a new build.
rm -rf "$worker"
mkdir -p "$worker/licenses"
cp "$products/mox" "$worker/mox"
cp Sources/MoxProtocol/BuildIdentity.swift "$worker/BuildIdentity.swift"
if [[ -d "$products/mox.dSYM" ]]; then ditto "$products/mox.dSYM" "$worker/mox.dSYM"; fi
cp "$products/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" "$worker/mlx.metallib"
for bundle in "$products"/*.bundle; do ditto "$bundle" "$worker/$(basename "$bundle")"; done
install -m 644 LICENSE "$worker/licenses/Mox-LICENSE"
python3 scripts/collect-licenses.py .build/package/SourcePackages/checkouts "$worker/licenses"
# Xcode can retain resources removed from older project configurations.
rm -rf ".build/app/Build/Products/$configuration/Mox.app"
xcodebuild -project Mox.xcodeproj -scheme Mox -configuration "$configuration" \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath ".build/app" \
  -skipPackagePluginValidation ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
destination="$PWD/.build/$configuration"
mkdir -p "$destination"
rm -rf "$destination/Mox.app" "$destination/Mox.app.dSYM"
ditto ".build/app/Build/Products/$configuration/Mox.app" "$destination/Mox.app"
if [[ -d ".build/app/Build/Products/$configuration/Mox.app.dSYM" ]]; then
  ditto ".build/app/Build/Products/$configuration/Mox.app.dSYM" "$destination/Mox.app.dSYM"
fi
printf 'App: %s/Mox.app\nCLI: %s/mox\n' "$destination" "$destination"
