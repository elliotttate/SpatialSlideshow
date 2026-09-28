# Spatial Slideshow

<img src="Assets/SpatialSlideshow.png" alt="Spatial Slideshow icon" width="160">

A native Mac slideshow that turns photos into moving 3D scenes using the **actual Apple Photos Reframe models** and Apple's Gaussian renderer. Browse a Photos album, press Play, and let it prepare the remaining items while the slideshow runs.

**0.9.0 is available for Apple Silicon and macOS 27.** The private frameworks and models are only verified on the development machine's macOS 27 installation. Other OS builds or hardware may behave differently. See the [release notes](Docs/RELEASE_NOTES_0.9.0.md) for realtime playback, interactive camera controls, and screen saver support.

## Requirements

- Apple Silicon Mac running macOS 27.
- Photos spatial/reframing model assets available for that Mac. The app checks them before processing and requests missing assets through macOS. If Apple requires setup in Photos, the app explains how to enable the feature and offers **Open Photos**. A third-party app cannot guarantee Apple's download will complete; see the [first-launch audit](Docs/FIRST_LAUNCH_AUDIT.md).
- For optional Apple edge expansion, Photos Clean Up assets. The same readiness check requests them and explains how to finish setup in Photos if needed.
- Optional **FLUX.2 Klein · MLX** and **FLUX · Draw Things** models download automatically on first use. The app installs its own verified Python runtime and dependencies; **Python, Homebrew, Xcode, and the Draw Things desktop app are not required**. Allow approximately **16 GB of free space** for a fresh local-model setup. See [MLX details](Docs/KleinSetup.html) or [Draw Things details](Docs/DrawThingsSetup.html).
- **Apple Photos Extend** is hidden under **Advanced research tools** on new installations. This [research backend](Docs/APPLE_EXTEND.md) is restricted to Trip and requires original Photos open, Xcode tools, and the separately configured temporary SIP-disabled setup; it uses Apple's online Extend service. Normal slideshow setup does not require these changes.
- Photos library permission when browsing albums, network access for photos kept only in iCloud, and free disk space for originals and prepared clips.

The app loads installed Apple assets in place and bundles no model weights. Normal backends process images locally. The optional native Extend research backend runs a one-shot expression inside original Photos and uses Apple's online service. No backend changes system files, OS security policy, entitlements, or original library photos.

## Use

1. Open **Spatial Slideshow.app**.
2. Choose **Browse Photo Albums**, select an album, and press **Play Album**. Or choose local image files and use **Build Slideshow**.
3. Open **Settings…** in the sidebar, or press **⌘,**, to control playback, camera movement, edge expansion, album contents, quality, and music.

**Settings → Models & Downloads → Download / Check Models** can prepare the required Apple models and the currently enabled expansion engine before playback. Setup shows progress, supports cancellation and retry, and keeps completed downloads for reuse. Models and runtimes are installed in your Application Support folder, outside the signed app. Existing custom Python environments are left untouched; choose **Reset to Automatic** to use the managed MLX runtime.

The image controls provide Previous, Play/Pause, Next, and one fullscreen toggle. **← / →** skip whole items, **Space** pauses, and **Esc** exits fullscreen. The complete control bar hides after idle. Playback prevents display sleep; pause, stop, or completion releases that request.

The app starts with previously prepared album items while new downloads begin. It prepares photos while playing or paused, with up to three original downloads and six buffered inputs. Every available photo that has not been shown in the current slideshow takes priority over repeats, including photos from previous sessions' caches. A cached photo is not shown again just because its new render finishes. If all ready photos have been seen while preparation continues, playback cycles through them in random rounds without immediate duplicates when alternatives exist. New photos interrupt those repeats; previous/next navigation still follows viewing history. A storage shortage or lost internet connection displays a warning and retries instead of silently discarding the affected photo. Long preparation steps show elapsed time; Apple model helpers are stopped after three minutes if they do not finish. MLX outpainting has a separate 30-minute limit; Draw Things has a six-minute outer limit. Playback readiness warnings and the latest item error are shown in the app, with a **Show Diagnostics** button. Stop cancels preparation.

## Settings

- **Playback:** fill the screen or fit with black bars; optional fades between photos; video sound.
- **Real-time 3D:** animate cached Gaussian scenes directly on the GPU. Off by default; see below.
- **Screen Saver:** select a prepared slideshow and install the native macOS screen saver. See setup below.
- **Camera movement:** time per photo, motion strength from 0.25× to 4×, and varied or fixed left/right, push-in, pull-back, diagonal, or vertical paths. Above 2×, movement curves into an elliptical orbit; from 2.5× it completes a full circle instead of retracing the outbound path, and higher strength widens the loop. Expansion zoom follows the orbit. Existing motion up to 2× stays unchanged; older higher-strength clips are regenerated with the new path.
- **Photo edge expansion:** choose **Apple Fast Clean Up**, **FLUX.2 Klein · MLX**, or **FLUX · Draw Things** to add 1–20% on each edge. Apple is the faster default. The two FLUX engines run locally with automatically installed models; Draw Things uses four-step FLUX.2 Klein 4B. The original composition stays close in view; extra surroundings provide space for movement. Larger extensions can soften or invent edge details. All three options retain the original full-resolution center outside a narrow blended seam.
- **Maximum zoom out:** an optional expansion override. Zero keeps the original framing behavior. Raising it lets the camera reveal more generated surroundings, up to twice the per-edge expansion percentage (40% with 20% expansion). The actual motion also follows the strength setting.
- **Apple Photos Extend:** an additional expansion choice for the temporary research setup above. Preserves the original photo, saves expanded stills for reuse, and follows the same expansion and zoom controls. New installations retain the existing expansion-off default.
- **Album:** shuffle and optionally include full-length videos. Live Photos use their still image. Video timing is independent of photo duration.
- **Photo quality:** full-quality latest edits or full-quality unedited originals, both with iCloud downloads; 1920 or 3840 pixels on the output's long edge.
- **Music:** local audio playlist, play/pause, skip, volume, and repeat. Music is played live and is not mixed into exported MP4s.

New installations start with **9 seconds, Strong motion, Varied movement, Fit with Black Bars, shuffle and fades on, full-quality unedited originals at 3840 pixels**, and videos and expansion off. Existing saved preferences are retained. Enabling expansion starts with 5% per edge and no extra zoom-out allowance unless those values were previously changed.

### Real-time 3D

Enable **Settings → Playback → Real-time 3D rendering**, then play or restart an album or file slideshow. This uses the same Apple Reframe scene and camera paths as clip generation, with a display-synchronized 60 fps target. New photos need inference once but skip movie encoding. Changing movement, duration, framing, output resolution or zoom-out does not regenerate the scene. Varied movement chooses a new path on each visit. Videos continue playing normally; cached movies can play while scenes prepare and act as fallbacks when available. Turn this option off to build and export an MP4.

Scenes persist in `Scene Cache/` with a 4 GiB least-recently-used limit, independent of camera settings. Original revisions, Photos source version, expansion backend/amount and inference pipeline version invalidate the scene. Current, incoming and up to six prepared-ahead scenes are protected from eviction; preparation waits at that limit, including while paused. Pausing reuses the displayed GPU frame instead of repeatedly drawing splats. Older unprotected scenes can be evicted and regenerated on a later play. Existing movie caches are kept; movies cannot reconstruct the original splats.

While a live photo is paused, **drag over the image**, **scroll with two fingers**, or hold **W/A/S/D** to explore its 3D viewpoint. W/S move up/down and A/D left/right. Movement stays within a bounded range, does not advance the photo's timeline, and needs no new inference. Releasing the controls holds that view; Space resumes with a smooth return to the slideshow path. Changing photos resets the manual offset. This applies to live scenes; videos and cached movie fallbacks pause normally.

The screen saver inherits this mode when you choose **Use This Slideshow** (or replay its already selected album with the option enabled). Update its installed component after updating the app. It loads cached scenes independently, never runs inference, and falls back to a matching prepared clip when one is available. A missing scene without a clip is skipped with diagnostics.

Real-time rendering uses more sustained GPU work than video decoding. It targets 60 fps, with live fades temporarily limited to a 1920-pixel long edge to leave room for two moving scenes; single scenes use the selected resolution up to 3840 pixels. Actual frame rate depends on the Mac, display and other GPU work. Regular clip playback remains the default.

### Use as a macOS screen saver

1. Play an album or build a file slideshow to prepare some clips.
2. Open **Settings → Screen Saver → Use This Slideshow**. New clips from that selection are added automatically as preparation continues. Playing another album does not change the screen saver selection.
3. Click **Install Screen Saver…**, then choose **Wallpaper → Screen Saver → Custom → Other → Spatial Slideshow** in macOS Settings (expand **Show All** under Other). If Settings was open during installation, close and reopen it to refresh the list. Set the idle delay in macOS Settings.
4. Stop regular slideshow playback or quit the app when finished preparing. Active slideshow playback intentionally keeps the display awake; the screen saver itself does not prevent display sleep.

The screen saver runs independently of the app, plays silently, and follows the framing, fade, and shuffle settings. It cycles through available clips without repeating a photo before the others have played. It reads the existing local clip cache; it does not duplicate videos, request Photos permission, download originals, or run AI models while idle. If there are no prepared clips, it shows setup instructions. Disabling **Use as a screen saver** stops it from displaying the shared playlist. macOS remains responsible for locking and requiring a password.

Screen saver compositing uses Metal at a target of 60 fps for smooth fades. Prepared clips retain their original 30 fps motion; the screen saver does not interpolate them. Live scenes generate new camera views each frame instead.

The app includes a signed `.saver` component built with Apple's [Screen Saver framework](https://developer.apple.com/documentation/ScreenSaver). Installation is per user at `~/Library/Screen Savers/Spatial Slideshow.saver`; its private playlist is at `~/Library/Application Support/Photos Spatial Slideshow/Screen Saver/Playlist.json`. Removing cached movies makes those items unavailable until prepared again. App updates include a new component; click **Update Screen Saver** after updating the app. To uninstall, remove the saver in macOS Screen Saver settings or move that `.saver` bundle to the Trash.

macOS can retain an older screen saver in its running host even after the file is updated. If an update still behaves like the previous version, log out and back in to reload it. Reopening Settings alone may not reload the component.

Settings save automatically. Framing, album fades, and sound update live. Motion, expansion, source quality, and album changes apply on the next play; **Restart Album** or **Rebuild Slideshow** applies them immediately. File slideshows bake in their framing and fades. **Save MP4** exports a built file slideshow; a streaming Photos album currently has no combined export.

## Cache and local files

Prepared photo clips and album videos survive app launches in:

```text
~/Library/Application Support/Photos Spatial Slideshow/
```

Matching photos, edit revisions, source versions, and render settings reuse completed clips. Shuffle order, album fit/fill, fades, and music do not require rendering photos again. Expansion amount/model revision and a nonzero zoom-out override have separate cache identities. Other compatible prepared variants can fill a wait while new clips render.

FLUX and Apple expansion clips have separate cache identities. FLUX also saves completed expanded stills under `Expanded Photos/FLUX.2 Klein/`, checking their output hashes before reuse. These survive app launches and changes to motion, duration, zoom-out allowance, or output resolution. A changed source, expansion amount, model, or processing version creates a new expansion. Existing Apple and unexpanded caches are retained.

FLUX's generated borders are matched to the source in perceptual color space before the full-resolution original is restored. This reduces purple/white-balance seams without tinting the original. The color-matching version is part of the cache identity, so earlier uncorrected expansions and clips are not replayed with the corrected pipeline. Invented scenery and structural joins can still differ from the photo.

The Draw Things option has its own expanded-still cache in `Expanded Photos/Draw Things FLUX/`. It uses a local server bound to loopback, started when a new expansion is needed. The app keeps it available between requests and stops it after ten idle minutes or when quitting. Cancellation stops an active owned generation. Its photo-expansion stage has a six-minute outer timeout. A changed expansion engine never reuses another engine's generated border. The three-photo M3 Max trial took approximately 16–30 seconds per expansion at the test resolution; a cold full-resolution Trip integration test took 51 seconds for expansion and compositing. Downloads, Apple Reframe and movie rendering add time. Border geometry and focus can still be imperfect.

Draw Things asks for a wider view of the same scene without emphasizing bokeh or blur. Its mask overlaps the original by 12 model pixels. Color correction continues through that boundary, and a multiband blend joins fine detail over an 18-model-pixel inner band while spreading lighting changes up to 64 model pixels into the generated border. At the normal 768-pixel model size, the inner band occupies about 2.3% of the source's long edge per side. The rest of the original stays pixel-exact; no whole-photo blur or extra Apple/cloud inference is applied. This processing revision has a new cache identity, so earlier expansions are regenerated when needed. See [the seam comparison](Docs/DRAWTHINGS_SEAM_REPAIR.md) for tested alternatives and limitations.

The same folder contains current and previous playback logs, album errors, retained failed-helper logs in `Diagnostics/`, temporary work, and saved render jobs. These files can contain source names and library identifiers; they are not part of this repository or its release. Originals and the Photos library are read only. Videos retain their original timing and audio; still-photo rendering uses a color-managed SDR pipeline.

## Build

Install full Xcode with the macOS 27 SDK, then:

```sh
./build_slideshow.sh
open "build/Spatial Slideshow.app"
```

The build uses `DEVELOPER_DIR` when supplied. Otherwise it tries the selected full Xcode, `/Applications/Xcode.app`, then `/Applications/Xcode-beta.app`, requiring a macOS 27 or newer SDK. Command Line Tools alone are insufficient. The build produces an arm64 app, native helpers, and the optional FLUX bridge/setup scripts; no third-party runtime, downloaded model, personal demo, or sample library is included.

```sh
DEVELOPER_DIR="/path/to/Xcode.app/Contents/Developer" ./build_slideshow.sh
```

Local builds are ad-hoc signed and not notarized. Published release downloads are Developer ID signed, notarized by Apple, and include a stapled ticket. Compatibility with future private framework revisions is not guaranteed.

## Tests

Python 3 and `ffmpeg`/`ffprobe` are needed only for tests. Test patterns, solid-color clips, and silent test tones are generated locally; no personal fixtures are included.

```sh
./test.sh                  # All synthetic tests; requires a logged-in desktop session
./test.sh --core           # Queue, storage, camera math, and photo/video cache tests
./test.sh --only navigation
```

Results, fixtures, and logs are written to ignored `build/tests/`. These tests do not read the Photos library or invoke private AI models. Playback checks exercise retained video layers in offscreen windows; visual composition and real macOS fullscreen transitions still need a live check.

For a separately requested model integration check, export a photo you own from the **Trip** album and run:

```sh
python3 Tests/run_model_test.py --album Trip /path/to/exported-trip-photo.heic
```

This optional test runs the actual expansion → Reframe → render pipeline, tests cache reuse in another process, and writes local outputs for visual review. Real-media project QA is restricted to Trip; there is no bundled test photo or automatic library lookup. See [testing details](Docs/TESTING.md).

## Release packaging

```sh
./Scripts/package_release.sh
```

This creates `dist/SpatialSlideshow-0.9.0-macOS-arm64.zip` and its SHA-256 file. It does not tag, publish, or upload anything. Set `SPATIAL_APP_OUTPUT` to build a separate release bundle without replacing a running development app. The archive contains the app, icon, and helper executables; Apple frameworks and models remain system dependencies.

For distribution, sign and notarize a copy of the built app using your Developer ID Application certificate and an existing `notarytool` Keychain profile:

```sh
SPATIAL_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
SPATIAL_NOTARY_PROFILE='YourKeychainProfile' \
./Scripts/notarize_release.sh "$PWD/build/Spatial Slideshow.app"
```

This signs embedded helpers before the app, enables Hardened Runtime with secure timestamps, applies and verifies the main app's Photos Library entitlement, submits to Apple, staples and validates the accepted ticket, and runs Gatekeeper assessment and Apple's pre-distribution checks. The final ZIP and checksum are written to `dist/notarized/`; an optional second argument chooses another output directory. The source app remains untouched. Credentials stay in Keychain, and submission logs remain in ignored `build/notarization/`. Publish this final archive, which contains the stapled app, instead of the submission ZIP. The script never uploads to GitHub.

[Architecture and research notes](Docs/RESEARCH.md) describe the working model routes and their limits. [Research probes](Research/README.md) preserve source-only diagnostics; no Apple binaries, disassembly, model weights, or decompiled implementations are included.

## License

Spatial Slideshow's source code and associated documentation are licensed under the [MIT License](LICENSE).

Apple's frameworks and model assets, and any separately downloaded third-party models, runtimes, or libraries, remain subject to their respective licenses. This project's MIT license does not grant rights to redistribute those components.
