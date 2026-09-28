#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source Scripts/common.sh
spatial_select_xcode
out="$PWD/build/research/extend-bridge"
mkdir -p "$out"
xcrun clang -arch arm64e -mmacosx-version-min=15.0 -fobjc-arc -dynamiclib \
    -framework Foundation -framework CoreImage -framework CoreGraphics -framework Security \
    Research/Extend/InProcessBridge.m -o "$out/SpatialExtendBridge.dylib"
xcrun clang -arch arm64e -mmacosx-version-min=15.0 -fobjc-arc -framework Foundation \
    Research/Extend/BridgeHost.m -o "$out/SpatialExtendBridgeHost"
# Match the architecture/signing arrangement already verified for this Mac's
# research host. No restricted entitlement or provisioning profile is added.
identity="${SPATIAL_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development:/ {print $2; exit}')}"
if [[ -z "$identity" ]]; then
    printf 'No local Apple Development identity found; bridge build remains unsigned.\n' >&2
    exit 2
fi
codesign --force --sign "$identity" "$out/SpatialExtendBridge.dylib"
codesign --force --sign "$identity" "$out/SpatialExtendBridgeHost"
codesign --verify --strict "$out/SpatialExtendBridge.dylib"
codesign --verify --strict "$out/SpatialExtendBridgeHost"
printf 'Built %s; no Photos attachment or model request was made.\n' "$out"
