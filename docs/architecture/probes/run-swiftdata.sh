#!/bin/bash
set -euo pipefail

# Use DEVELOPER_DIR to select Xcode without changing the machine-wide setting.
probe_source_dir=$(cd "$(dirname "$0")" && pwd)
developer_path=$(xcode-select -p)
developer_path=${DEVELOPER_DIR:-$developer_path}
if [[ ! -d "$developer_path/Platforms/MacOSX.platform" ]]; then
  echo "BLOCKED: full Xcode required; selected: $developer_path" >&2
  echo "Install Xcode, complete first launch, then run with DEVELOPER_DIR pointing to Contents/Developer." >&2
  exit 2
fi

probe_output=$(mktemp -d /tmp/mox-swiftdata-probe.XXXXXX)
echo "Evidence directory: $probe_output"
xcrun swiftc -swift-version 6 -parse-as-library \
  -module-cache-path "$probe_output/cache" \
  "$probe_source_dir/SwiftDataProbe.swift" -o "$probe_output/store-probe"
"$probe_output/store-probe" write "$probe_output/probe.store" > "$probe_output/write.txt"
"$probe_output/store-probe" read "$probe_output/probe.store" > "$probe_output/read.txt"
printf '%s\n' '["interrupted"]' > "$probe_output/expected.txt"
diff -u "$probe_output/expected.txt" "$probe_output/write.txt"
diff -u "$probe_output/expected.txt" "$probe_output/read.txt"
echo "PASS: explicit save and cross-process reopen"
