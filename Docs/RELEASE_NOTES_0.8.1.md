# Spatial Slideshow 0.8.1

First-run model setup now happens in the app. Missing optional FLUX runtimes and models install automatically when starting playback, or through **Settings → Models & Downloads → Download / Check Models**.

## Changes

- Install a verified portable Python, pinned Apple Silicon dependencies, and the selected local FLUX model without requiring Python, Homebrew, Xcode, or the Draw Things desktop app.
- Show setup progress, support cancellation and retry, resume interrupted Draw Things downloads, and check disk space before large downloads. Allow about 16 GB free for a fresh local-model installation.
- Verify and repair managed runtimes while leaving custom Python environments and model folders untouched. Keep downloads outside the signed app.
- Resolve active Apple Reframe and Clean Up model sets, request missing assets through macOS, and provide one clear setup message with Open Photos when Apple requires manual completion. Apple's model downloads remain under Apple's control; automatic completion on a fresh Mac is not guaranteed.
- Hide the Trip-only native Photos Extend experiment under Experimental research tools for new installations. Normal playback needs no security-setting changes.
- Fix the signed app's Photos permission flow: include the Photos Library entitlement required by Hardened Runtime, so macOS can show its permission prompt instead of immediately denying library access.
- Recover from occupied local server ports without stopping other services. Improve model-download and renderer error messages, remove the dormant demo loader, and clean up large temporary scenes after successful file builds.

Existing photo caches, model files, and saved preferences are retained. Expansion remains off by default.

## Validation

All 16 native synthetic suites and 48 Python tests passed. Portable Python bootstrapping, dependency installation, checksum enforcement, interruption/retry, damaged-package repair, process-group cancellation, and occupied-port recovery were tested in isolated directories. The signed helpers passed both Apple Clean Up and Draw Things expansion → Apple Reframe → movie tests on a Trip photo, including persistent reuse. See the [first-launch audit](FIRST_LAUNCH_AUDIT.md) for exact coverage and remaining clean-Mac and MLX verification limits.

## Download

Download `SpatialSlideshow-0.8.1-macOS-arm64.zip`, extract it, and open **Spatial Slideshow.app**. Requires Apple Silicon, macOS 27, and compatible Apple Photos Reframe assets. The release is Developer ID signed, notarized by Apple, and includes a stapled ticket.

This is an experimental prerelease using private Apple APIs. Apple frameworks, model weights, personal media, generated caches, and private diagnostic logs are not included.
