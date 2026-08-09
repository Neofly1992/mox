#!/bin/bash
# Compile and run the MoxGUI startup-flow smoke driver. Three modes:
#   - daemon-running
#   - daemon-not-running-disabled
#   - daemon-not-running-enabled
# Each prints the bootstrap decision path AppState takes for that
# daemonReachable × daemonEnabled combination.
set -euo pipefail
cd "$(dirname "$0")/../.."

BUILD_DIR=".build/x86_64-apple-macosx/debug"
MODULES_DIR="$BUILD_DIR/Modules"
OBJ_DIR="$BUILD_DIR"
DRIVER="scripts/mox-gui-smoke/mox-gui-smoke.swift"
OUT_DIR="$(mktemp -d)/mox-gui-smoke"
mkdir -p "$OUT_DIR"

swiftc \
    -parse-as-library \
    -I "$MODULES_DIR" \
    -o "$OUT_DIR/mox-gui-smoke" \
    "$DRIVER" \
    $(find "$OBJ_DIR/MoxShared.build" "$OBJ_DIR/MoxGUIClient.build" -name "*.o" 2>/dev/null) \
    2>&1 | tee "$OUT_DIR/build.log"

SCENARIO="${1:-all}"
if [ "$SCENARIO" = "all" ]; then
    for s in daemon-running daemon-not-running-disabled daemon-not-running-enabled; do
        echo
        echo "###############################################"
        MOX_SMOKE_SCENARIO="$s" "$OUT_DIR/mox-gui-smoke"
    done
    echo
else
    MOX_SMOKE_SCENARIO="$SCENARIO" "$OUT_DIR/mox-gui-smoke"
fi
