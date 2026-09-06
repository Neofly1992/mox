#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Full Xcode + its optional Metal Toolchain are required. On a fresh Xcode install:
# xcodebuild -downloadComponent MetalToolchain
xcodebuild -scheme mox -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO build
products="$PWD/.build/xcode/Build/Products/Release"
output="$PWD/.build/m1"
mkdir -p "$output"
cp "$products/mox" "$output/mox"
cp "$products/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" "$output/mlx.metallib"
for bundle in "$products"/*.bundle; do
  ditto "$bundle" "$output/$(basename "$bundle")"
done
mkdir -p "$output/licenses"
cp LICENSE "$output/licenses/Mox-LICENSE"
for dependency in .build/xcode/SourcePackages/checkouts/*; do
  for license in "$dependency"/LICENSE* "$dependency"/NOTICE*; do
    if [[ -f "$license" ]]; then
      cp "$license" "$output/licenses/$(basename "$dependency")-$(basename "$license")"
    fi
  done
done
printf 'M1 CLI: %s/mox\n' "$output"
