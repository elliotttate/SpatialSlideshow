#!/bin/bash
# Shared full-Xcode selection. Executing this file prints the chosen path.
set -euo pipefail

spatial_select_xcode() {
    if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
        echo 'Spatial Slideshow requires an Apple Silicon Mac.' >&2
        return 1
    fi
    local candidate sdk
    local candidates=()
    if [[ -n "${DEVELOPER_DIR:-}" ]]; then
        candidates=("$DEVELOPER_DIR")
    else
        candidates=("$(xcode-select -p 2>/dev/null || true)" "/Applications/Xcode.app/Contents/Developer" "/Applications/Xcode-beta.app/Contents/Developer")
    fi
    for candidate in "${candidates[@]}"; do
        [[ -d "$candidate/Platforms/MacOSX.platform" ]] || continue
        sdk=$(DEVELOPER_DIR="$candidate" xcrun --sdk macosx --show-sdk-version 2>/dev/null) || continue
        [[ "${sdk%%.*}" =~ ^[0-9]+$ ]] || continue
        if (( ${sdk%%.*} >= 27 )); then
            export DEVELOPER_DIR="$candidate"
            return 0
        fi
    done
    echo 'Install full Xcode with the macOS 27 SDK, or set DEVELOPER_DIR to its Contents/Developer directory.' >&2
    return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    spatial_select_xcode
    printf '%s\n' "$DEVELOPER_DIR"
fi
