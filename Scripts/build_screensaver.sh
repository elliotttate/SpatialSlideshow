#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/common.sh
spatial_select_xcode
saver="${1:?Pass an output .saver path}"
mkdir -p "$saver/Contents/MacOS" "$saver/Contents/Resources"
mkdir -p build/Helpers
xcrun clang++ -O2 -std=c++17 -target arm64-apple-macos27.0 -fobjc-arc -c Sources/LiveGaussianRenderer.mm -o build/Helpers/LiveGaussianRenderer.o
xcrun swiftc -O -emit-library -module-name SpatialScreenSaver -target arm64-apple-macos27.0 \
    -file-prefix-map "$PWD=." -framework ScreenSaver \
    -import-objc-header Sources/LiveGaussianRenderer.h build/Helpers/LiveGaussianRenderer.o -lc++ Sources/SceneCache.swift Sources/MetalPlaybackCanvas.swift Sources/LivePlaybackSurface.swift Sources/SpatialScreenSaverView.swift Sources/ScreenSaverPlaylist.swift Sources/ContinuousPlayback.swift \
    -o "$saver/Contents/MacOS/SpatialScreenSaver"
cp Assets/SpatialSlideshow.icns "$saver/Contents/Resources/SpatialSlideshow.icns"
cat > "$saver/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.photos-spatial-slideshow.screensaver</string>
<key>CFBundleName</key><string>Spatial Slideshow</string>
<key>CFBundleExecutable</key><string>SpatialScreenSaver</string>
<key>CFBundlePackageType</key><string>BNDL</string>
<key>CFBundleShortVersionString</key><string>${SPATIAL_VERSION:-0.9.0}</string>
<key>CFBundleVersion</key><string>${SPATIAL_BUILD:-900}</string>
<key>CFBundleIconFile</key><string>SpatialSlideshow.icns</string>
<key>LSMinimumSystemVersion</key><string>27.0</string>
<key>NSPrincipalClass</key><string>SpatialSlideshowScreenSaverView</string>
</dict></plist>
PLIST
codesign --force --sign - "$saver"
codesign --verify --strict "$saver"
