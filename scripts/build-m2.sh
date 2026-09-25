#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-Release}"
case "$configuration" in
  Debug) debug_information=dwarf ;;
  Release) debug_information=dwarf-with-dsym ;;
  *) echo 'Usage: scripts/build-m2.sh [Debug|Release]' >&2; exit 2 ;;
esac
if [[ $# -gt 1 ]]; then echo 'Expected one build configuration.' >&2; exit 2; fi
python3 scripts/stamp-m2-build.py
python3 scripts/generate-xcode-project.py
mkdir -p .build/m2-package.xcworkspace
python3 - <<'PY'
from pathlib import Path
import xml.etree.ElementTree as E
w=E.Element('Workspace',version='1.0')
E.SubElement(w,'FileRef',location='absolute:'+str(Path.cwd()))
E.ElementTree(w).write('.build/m2-package.xcworkspace/contents.xcworkspacedata',encoding='utf-8',xml_declaration=True)
PY
xcodebuild -workspace .build/m2-package.xcworkspace -scheme mox -configuration "$configuration" \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode \
  -skipPackagePluginValidation ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO DEBUG_INFORMATION_FORMAT="$debug_information" build
products="$PWD/.build/xcode/Build/Products/$configuration"
worker="$PWD/.build/m2-worker/$configuration"
# Staging directories are generated outputs. Never merge obsolete bundles into a new build.
rm -rf "$worker"
mkdir -p "$worker/licenses"
cp "$products/mox" "$worker/mox"
if [[ -d "$products/mox.dSYM" ]]; then ditto "$products/mox.dSYM" "$worker/mox.dSYM"; fi
cp "$products/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" "$worker/mlx.metallib"
for bundle in "$products"/*.bundle; do ditto "$bundle" "$worker/$(basename "$bundle")"; done
install -m 644 LICENSE "$worker/licenses/Mox-LICENSE"
for dependency in .build/xcode/SourcePackages/checkouts/*; do
  for license in "$dependency"/LICENSE* "$dependency"/NOTICE*; do
    if [[ -f "$license" ]]; then install -m 644 "$license" "$worker/licenses/$(basename "$dependency")-$(basename "$license")"; fi
  done
done
# Xcode can retain resources removed from older project configurations.
rm -rf ".build/m2-app/Build/Products/$configuration/Mox.app"
xcodebuild -project Mox.xcodeproj -scheme Mox -configuration "$configuration" \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/m2-app \
  -skipPackagePluginValidation ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
destination="$PWD/.build/m2/$configuration"
mkdir -p "$destination"
rm -rf "$destination/Mox.app" "$destination/Mox.app.dSYM"
ditto ".build/m2-app/Build/Products/$configuration/Mox.app" "$destination/Mox.app"
if [[ -d ".build/m2-app/Build/Products/$configuration/Mox.app.dSYM" ]]; then
  ditto ".build/m2-app/Build/Products/$configuration/Mox.app.dSYM" "$destination/Mox.app.dSYM"
fi
printf 'M2 %s App: %s/Mox.app\nM2 CLI: %s/mox\n' "$configuration" "$destination" "$worker"
