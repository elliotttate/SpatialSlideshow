# Spatial Slideshow 0.8.0

Album playback now prioritizes photos that have not been shown in the current slideshow, including photos prepared during earlier sessions. Optional local FLUX outpainting, clearer preparation progress, and a native Apple Photos Extend backend are also included.

## Playback and caching

- Show every available unseen photo before repeating. When waiting for preparation, shuffle through complete rounds of ready photos, avoiding consecutive duplicates when alternatives exist.
- Reuse cached photos immediately without queuing them again when a newer render finishes. New unseen photos interrupt waiting repeats; Previous/Next continues to follow viewing history.
- Preserve unseen cached items when preparation finishes, and retain pause, crossfade, and final-frame behavior. Viewing history starts fresh for each slideshow; prepared media remains cached across launches.

## Expansion options

- Add **FLUX · Draw Things**, using a separately installed, pinned FLUX.2 Klein 4B runtime on Apple Silicon, and **FLUX.2 Klein · MLX** as local outpainting choices. Both save expanded stills independently of camera-motion clips.
- Improve Draw Things scene-continuation prompts, overlapping masks, color continuity, and multiband seam blending while preserving the full-resolution source interior. Earlier processing revisions have separate cache identities.
- Add setup instructions, runtime checks, cancellation, and idle shutdown of the app-owned Draw Things server.
- Include **Apple Photos Extend** as an opt-in research backend restricted to the Trip album. It uses Apple's online service through the original Photos process and requires the separately configured temporary SIP-disabled research environment and Xcode tools. Network retries and persisted rate-limit cooldowns allow cached playback to continue. The app does not change security settings.

Generated borders can still have visible seams, incorrect geometry, or mismatched depth of field. The improvements do not make every expansion seamless. Apple Extend has service quotas and is unsuitable for unrestricted album-wide generation. The normal default remains expansion off; existing preferences are retained.

## Progress and diagnostics

- Show elapsed time and clearer errors while waiting for iCloud originals, video preparation, or model helpers.
- Bound helper execution, cancel unresponsive children, and retain failed-helper logs accessible through **Show Diagnostics**.
- Retry offline and low-storage conditions without silently discarding the pending photo.

## Validation

- All **14 synthetic suites passed**, covering preparation, storage recovery, photo/video cache persistence, playback, displayed video layers, navigation, fullscreen controls, music, display sleep, helper timeouts, and native Extend recovery.
- All **32 Python tests passed**, covering local expansion geometry, source preservation, color/seam blending, cache corruption, local-server ownership, cancellation, and native research guards without model requests.
- The release app and source-only research probes built successfully. The archive passed integrity and extracted-app signature checks.
- The Developer ID signed app passed both Apple Fast Clean Up and Draw Things expansion → Apple Reframe → movie tests on a Trip photo, including persistent-cache checks. Apple accepted notarization with no issues; the stapled app passes Apple's pre-distribution checks.
- The shuffle update was checked live on Trip with 14 distinct photos and no repeats in the observed startup sequence. Earlier Trip-only checks exercised the Draw Things expansion → Apple Reframe → video pipeline, changed-motion expanded-still reuse, and clip reuse in a separate process.

## Download and requirements

Download `SpatialSlideshow-0.8.0-macOS-arm64.zip`, extract it, and open **Spatial Slideshow.app**. Requires Apple Silicon, macOS 27, and supported Photos Reframe models already installed on the Mac. Optional expansion engines have additional setup requirements; see the README.

The download is signed with **Developer ID Application: Brian Tate (RH4U5VJHM6)**, notarized by Apple, and includes a stapled notarization ticket. The app uses private APIs; notarization does not establish compatibility across other Macs or macOS builds. Apple frameworks, model weights, personal photos, generated caches, and private diagnostic logs are not included.
