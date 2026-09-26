#!/bin/bash
# Produces local artifacts only. Does not create a tag or publish a release.
set -euo pipefail
cd "$(dirname "$0")/.."
version="${SPATIAL_VERSION:-0.7.0}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid version' >&2; exit 1; }
export SPATIAL_APP_OUTPUT="$PWD/build/Spatial Slideshow.app"
./build_slideshow.sh
mkdir -p dist
archive="SpatialSlideshow-$version-macOS-arm64.zip"
[[ ! -e "dist/$archive" ]] || { echo "dist/$archive already exists; move it aside before packaging again." >&2; exit 1; }
codesign --verify --deep --strict "$SPATIAL_APP_OUTPUT"
ditto -c -k --sequesterRsrc --keepParent "$SPATIAL_APP_OUTPUT" "dist/$archive"
(cd dist && shasum -a 256 "$archive" > "$archive.sha256")
printf 'Release archive: %s/dist/%s\n' "$PWD" "$archive"
printf '%s\n' 'This is an ad-hoc signed development build; it is not notarized.'
