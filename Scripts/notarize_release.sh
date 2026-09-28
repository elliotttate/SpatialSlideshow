#!/bin/bash
# Sign and notarize a copy of an existing app. Never publishes to GitHub.
# Credentials stay in Keychain; pass only its profile name, not a password.
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/common.sh
spatial_select_xcode

[[ $# -ge 1 && $# -le 2 ]] || {
    echo 'Usage: Scripts/notarize_release.sh /path/to/Spatial\ Slideshow.app [output-directory]' >&2
    exit 1
}
sign_id="${SPATIAL_SIGN_IDENTITY:?Set SPATIAL_SIGN_IDENTITY to your Developer ID Application identity}"
profile="${SPATIAL_NOTARY_PROFILE:?Set SPATIAL_NOTARY_PROFILE to an existing notarytool Keychain profile}"
[[ "$sign_id" == 'Developer ID Application: '* ]] || {
    echo 'Use a Developer ID Application certificate for distribution.' >&2
    exit 1
}
source_app="$(cd "$1" && pwd -P)"
[[ "$source_app" == *.app && -f "$source_app/Contents/Info.plist" ]] || {
    echo 'Expected an existing .app bundle.' >&2; exit 1
}
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$source_app/Contents/Info.plist")
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid app version' >&2; exit 1; }
destination="${2:-$PWD/dist/notarized}"
mkdir -p "$destination" "$PWD/build/notarization"
destination="$(cd "$destination" && pwd -P)"
archive="SpatialSlideshow-$version-macOS-arm64.zip"
[[ ! -e "$destination/$archive" && ! -e "$destination/$archive.sha256" ]] || {
    echo 'Release files already exist; choose another output directory.' >&2; exit 1
}

# Match SpliceKit: verify credentials, then sign embedded code inside-out with
# Hardened Runtime and secure timestamps. The main app must opt in to Photos
# access or macOS denies PhotoKit without displaying the permission prompt.
xcrun notarytool history --keychain-profile "$profile" >/dev/null
work=$(mktemp -d "$PWD/build/notarization/release-XXXXXX")
app="$work/Spatial Slideshow.app"
printf 'Signing workspace: %s\n' "$work"
ditto "$source_app" "$app"
for helper in GenerateScene RenderSlideshow ExpandPhoto PrepareExpansionPhoto AppleModelSetup; do
    codesign --force --options runtime --timestamp --sign "$sign_id" "$app/Contents/Resources/$helper"
done
codesign --force --options runtime --timestamp --sign "$sign_id" \
    --entitlements SpatialSlideshow.entitlements "$app"
codesign --verify --deep --strict "$app"
codesign -d --entitlements :- "$app" > "$work/entitlements.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.personal-information.photos-library' "$work/entitlements.plist")" == true ]] || {
    echo 'The app is missing its required Photos Library entitlement.' >&2; exit 1
}

ditto -c -k --sequesterRsrc --keepParent "$app" "$work/submission.zip"
xcrun notarytool submit "$work/submission.zip" --keychain-profile "$profile" \
    --wait --output-format json > "$work/submission.json"
submission_id=$(/usr/bin/plutil -extract id raw -o - "$work/submission.json")
xcrun notarytool log "$submission_id" --keychain-profile "$profile" "$work/notary-log.json"
status=$(/usr/bin/plutil -extract status raw -o - "$work/submission.json")
[[ "$status" == Accepted ]] || {
    printf 'Notarization status: %s. Inspect %s/notary-log.json\n' "$status" "$work" >&2
    exit 1
}

# ZIP files cannot hold a stapled ticket themselves. Staple the app, then make
# the final distribution ZIP so the ticket survives extraction and offline use.
xcrun stapler staple "$app"
xcrun stapler validate "$app"
codesign --verify --deep --strict "$app"
spctl --assess --type execute --verbose=4 "$app"
syspolicy_check distribution "$app"
ditto -c -k --sequesterRsrc --keepParent "$app" "$work/$archive"
(cd "$work" && shasum -a 256 "$archive" > "$archive.sha256")
mv "$work/$archive" "$work/$archive.sha256" "$destination/"
printf 'Signed, notarized release: %s/%s\n' "$destination" "$archive"
printf 'Apple submission ID: %s\n' "$submission_id"
