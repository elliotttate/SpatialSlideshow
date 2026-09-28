#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
source Scripts/common.sh
spatial_select_xcode

version="${SPATIAL_VERSION:-0.9.0}"
build_number="${SPATIAL_BUILD:-900}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$build_number" =~ ^[0-9]+$ ]] || { echo 'Invalid version/build number' >&2; exit 1; }
app="${SPATIAL_APP_OUTPUT:-$PWD/build/Spatial Slideshow.app}"
helpers="$PWD/build/Helpers"
mkdir -p "$helpers" "$app/Contents/MacOS" "$app/Contents/Resources"
swift_flags=(-O -parse-as-library -target arm64-apple-macos27.0 -file-prefix-map "$PWD=.")
xcrun swiftc "${swift_flags[@]}" -I Stubs -L Stubs -lAlchemistBase Sources/GenerateScene.swift Sources/ColorManagedImage.swift Sources/AppleModelLocations.swift -o "$helpers/GenerateScene"
xcrun swiftc "${swift_flags[@]}" -I Stubs -L Stubs -lPhotosGenerativeServices Sources/ExpandPhoto.swift Sources/ColorManagedImage.swift Sources/AppleModelLocations.swift -o "$helpers/ExpandPhoto"
xcrun clang -O2 -target arm64-apple-macos27.0 -fobjc-arc -fmodules -framework Foundation Sources/AppleModelSetup.m -o "$helpers/AppleModelSetup"
xcrun swiftc "${swift_flags[@]}" Sources/PrepareExpansionPhoto.swift Sources/ColorManagedImage.swift -o "$helpers/PrepareExpansionPhoto"
xcrun clang++ -O2 -std=c++17 -target arm64-apple-macos27.0 -ffile-prefix-map="$PWD=." -fobjc-arc -framework Foundation -framework Metal -framework CoreImage -framework CoreGraphics -framework AVFoundation -framework CoreVideo -framework CoreMedia Sources/RenderSlideshow.mm -o "$helpers/RenderSlideshow"
xcrun clang++ -O2 -std=c++17 -target arm64-apple-macos27.0 -fobjc-arc -c Sources/LiveGaussianRenderer.mm -o "$helpers/LiveGaussianRenderer.o"
xcrun swiftc "${swift_flags[@]}" -import-objc-header Sources/LiveGaussianRenderer.h "$helpers/LiveGaussianRenderer.o" -lc++ Sources/ScenePreparationWindow.swift Sources/SceneCache.swift Sources/MetalPlaybackCanvas.swift Sources/LivePlaybackSurface.swift Sources/SlideshowApp.swift Sources/AlbumBrowser.swift Sources/PlaybackPipeline.swift Sources/HelperProcess.swift Sources/RuntimeInstaller.swift Sources/NativeExtendRecovery.swift Sources/PhotoExpansion.swift Sources/AlbumPreparationQueue.swift Sources/StorageRecovery.swift Sources/VideoClipCache.swift Sources/ClipCacheCatalog.swift Sources/ContinuousPlayback.swift Sources/SlideshowPlayerView.swift Sources/SlideshowOptions.swift Sources/MusicPlayback.swift Sources/DisplaySleepInhibitor.swift Sources/ScreenSaverPlaylist.swift Sources/ScreenSaverController.swift -o "$app/Contents/MacOS/SpatialSlideshow"
bash Scripts/build_screensaver.sh "$app/Contents/Resources/Spatial Slideshow.saver"
cp "$helpers/GenerateScene" "$helpers/RenderSlideshow" "$helpers/ExpandPhoto" "$helpers/PrepareExpansionPhoto" "$helpers/AppleModelSetup" "$app/Contents/Resources/"
cp Sources/ExpandPhotoKlein.py Sources/KleinColorMatch.py Scripts/setup_klein.py Docs/KleinSetup.html "$app/Contents/Resources/"
cp Scripts/SetupSupport.py Scripts/drawthings-requirements.lock Scripts/klein-requirements.lock "$app/Contents/Resources/"
cp Sources/ExpandPhotoDrawThings.py Scripts/setup_drawthings.py Docs/DrawThingsSetup.html "$app/Contents/Resources/"
cp Sources/ExpandPhotoNative.py Research/Extend/attach_jit.py Research/Extend/JITRequest.expr "$app/Contents/Resources/"
cp Assets/SpatialSlideshow.icns "$app/Contents/Resources/SpatialSlideshow.icns"
# No personal media or sample library is bundled.
rm -f "$app/Contents/Resources/Demo.mp4"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.photos-spatial-slideshow</string>
<key>CFBundleName</key><string>Spatial Slideshow</string>
<key>CFBundleExecutable</key><string>SpatialSlideshow</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$build_number</string>
<key>CFBundleIconFile</key><string>SpatialSlideshow.icns</string>
<key>LSMinimumSystemVersion</key><string>27.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPhotoLibraryUsageDescription</key><string>Browse your albums and play their photos and videos in local spatial slideshows.</string>
</dict></plist>
PLIST
for helper in GenerateScene RenderSlideshow ExpandPhoto PrepareExpansionPhoto AppleModelSetup; do
    codesign --force --sign - "$app/Contents/Resources/$helper"
done
codesign --force --sign - --entitlements SpatialSlideshow.entitlements "$app"
codesign --verify --deep --strict "$app"
printf 'Built: %s\n' "$app"
