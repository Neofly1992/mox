#!/bin/bash
set -euo pipefail
source_dir="$SRCROOT/.build/$CONFIGURATION"
helpers="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
target_dir="$helpers/MoxWorker.app/Contents"
if [[ ! -f "$source_dir/mox" || ! -f "$source_dir/mlx.metallib" ]]; then
  echo "Missing $CONFIGURATION worker; run scripts/build.sh $CONFIGURATION first." >&2
  exit 1
fi
current_id=$(python3 "$SRCROOT/scripts/stamp-build.py" --check) || exit 1
if [[ ! -f "$source_dir/BuildIdentity.swift" ]] || ! cmp -s "$source_dir/BuildIdentity.swift" "$SRCROOT/Sources/MoxProtocol/BuildIdentity.swift"; then
  echo "Staged worker is stale ($current_id); run scripts/build.sh $CONFIGURATION." >&2
  exit 1
fi
mkdir -p "$target_dir/MacOS" "$target_dir/Resources"
cp "$source_dir/mox" "$target_dir/MacOS/mox"
for bundle in "$source_dir"/*.bundle; do ditto "$bundle" "$target_dir/Resources/$(basename "$bundle")"; done
ditto "$source_dir/licenses" "$target_dir/Resources/licenses"
python3 - "$target_dir/Info.plist" "$SRCROOT/VERSION" "$current_id" <<'PYPLIST'
import plistlib,sys
from pathlib import Path
version=Path(sys.argv[2]).read_text().strip()
with open(sys.argv[1],'wb') as output:
    plistlib.dump({'CFBundleIdentifier':'dev.mox.worker','CFBundleExecutable':'mox',
        'CFBundlePackageType':'APPL','CFBundleShortVersionString':version,
        'CFBundleVersion':version,'MoxBuildID':sys.argv[3],'LSBackgroundOnly':True},output)
PYPLIST
/usr/bin/codesign --force --sign - "$helpers/MoxWorker.app"
