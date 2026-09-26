#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
source Scripts/common.sh
spatial_select_xcode
exec python3 Tests/run_tests.py "$@"
