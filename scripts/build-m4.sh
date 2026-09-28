#!/bin/bash
set -euo pipefail
export MOX_BUILD_MILESTONE=m4
exec "$(dirname "$0")/build-m3.sh" "$@"
