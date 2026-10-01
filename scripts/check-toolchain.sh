#!/bin/bash
set -euo pipefail
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo 'Requires an Apple Silicon Mac.' >&2; exit 1; }
xcodebuild -version
xcrun swift --version
xcrun swift --version | python3 -c 'import re,sys; m=re.search(r"Swift version (\d+)\.(\d+)",sys.stdin.read()); sys.exit(0 if m and tuple(map(int,m.groups())) >= (6,3) else "Swift 6.3+ is required.")'
if [[ "${1:-}" == metal ]]; then xcrun metal -v; fi
