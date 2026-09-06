#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${MOX_TEST_MODEL:?Set MOX_TEST_MODEL to an absolute local MLX model directory}"
if [[ ! -f .build/m1/mlx.metallib ]]; then
  echo 'Run scripts/build-m1.sh first (Metal resource is missing).' >&2
  exit 1
fi
swift test --scratch-path .build/m1-tests --skip realLocalInference
binary_dir="$(swift build --scratch-path .build/m1-tests --show-bin-path)"
# MLX officially searches next to the linked binary. SwiftPM doesn't compile Metal.
for test_bundle in "$binary_dir"/*PackageTests.xctest; do
  cp .build/m1/mlx.metallib "$test_bundle/Contents/MacOS/mlx.metallib"
done
MOX_TEST_MODEL="$MOX_TEST_MODEL" swift test --scratch-path .build/m1-tests --skip-build --filter realLocalInference
