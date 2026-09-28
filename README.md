# Spatial Slideshow

<img src="Assets/SpatialSlideshow.png" alt="Spatial Slideshow icon" width="160">

A native Mac slideshow that turns photos into moving 3D scenes using the **actual Apple Photos Reframe models** and Apple's Gaussian renderer. Browse a Photos album, press Play, and let it prepare the remaining items while the slideshow runs.

**0.8.0 is an experimental prerelease for Apple Silicon and macOS 27.** The private frameworks and models are only verified on the development machine's macOS 27 installation. Other OS builds or hardware may behave differently. See the [release notes](Docs/RELEASE_NOTES_0.8.0.md) for changes since 0.7.0.

## Requirements

- Apple Silicon Mac running macOS 27.
- Photos spatial/reframing model assets already installed on that Mac. Use the corresponding feature in Photos first so macOS can obtain its supported models.
- For optional Apple edge expansion, the installed Photos Clean Up models. Open Clean Up in Photos first if the app reports they are unavailable. The alternative **FLUX.2 Klein · MLX** option requires its separate local runtime and weights; see [setup instructions](Docs/KleinSetup.html).
- **FLUX · Draw Things** is another optional local expansion engine using four-step FLUX.2 Klein 4B. Its separate installation is described in [Draw Things setup](Docs/DrawThingsSetup.html).
- **Apple Photos Extend** is an opt-in [research backend](Docs/APPLE_EXTEND.md), currently restricted to Trip. It requires original Photos open, Xcode tools, and the user-configured temporary SIP-disabled setup; it uses Apple's online Extend service.
- Photos library permission when browsing albums, network access for photos kept only in iCloud, and free disk space for originals and prepared clips.

The app loads installed Apple assets in place and bundles no model weights. Normal backends process images locally. The optional native Extend research backend runs a one-shot expression inside original Photos and uses Apple's online service. No backend changes system files, OS security policy, entitlements, or original library photos.

## Use

1. Open **Spatial Slideshow.app**.
2. Choose **Browse Photo Albums**, select an album, and press **Play Album**. Or choose local image files and use **Build Slideshow**.
3. Open **Settings…** in the sidebar, or press **⌘,**, to control playback, camera movement, edge expansion, album contents, quality, and music.

The image controls provide Previous, Play/Pause, Next, and one fullscreen toggle. **← / →** skip whole items, **Space** pauses, and **Esc** exits fullscreen. The complete control bar hides after idle. Playback prevents display sleep; pause, stop, or completion releases that request.

The app starts with previously prepared album items while new downloads begin. It prepares photos while playing or paused, with up to three original downloads and six buffered inputs. Every available photo that has not been shown in the current slideshow takes priority over repeats, including photos from previous sessions' caches. A cached photo is not shown again just because its new render finishes. If all ready photos have been seen while preparation continues, playback cycles through them in random rounds without immediate duplicates when alternatives exist. New photos interrupt those repeats; previous/next navigation still follows viewing history. A storage shortage or lost internet connection displays a warning and retries instead of silently discarding the affected photo. Long preparation steps show elapsed time; Apple model helpers are stopped after three minutes if they do not finish. MLX outpainting has a separate 30-minute limit; Draw Things has a six-minute outer limit. Playback readiness warnings and the latest item error are shown in the app, with a **Show Diagnostics** button. Stop cancels preparation.

## Settings

- **Playback:** fill the screen or fit with black bars; optional fades between photos; video sound.
- **Camera movement:** time per photo, motion strength, and varied or fixed left/right, push-in, pull-back, diagonal, or vertical paths.
- **Photo edge expansion:** choose **Apple Fast Clean Up**, **FLUX.2 Klein · MLX**, or **FLUX · Draw Things** to add 1–20% on each edge. Apple is the faster default. The two FLUX engines run locally with separately installed models; Draw Things uses four-step FLUX.2 Klein 4B. The original composition stays close in view; extra surroundings provide space for movement. Larger extensions can soften or invent edge details. All three options retain the original full-resolution center outside a narrow blended seam.
- **Maximum zoom out:** an optional expansion override. Zero keeps the original framing behavior. Raising it lets the camera reveal more generated surroundings, up to twice the per-edge expansion percentage (40% with 20% expansion). The actual motion also follows the strength setting.
- **Apple Photos Extend research preview:** an additional expansion choice for the temporary research setup above. Preserves the original photo, saves expanded stills for reuse, and follows the same expansion and zoom controls. New installations retain the existing expansion-off default.
- **Album:** shuffle and optionally include full-length videos. Live Photos use their still image. Video timing is independent of photo duration.
- **Photo quality:** full-quality latest edits or full-quality unedited originals, both with iCloud downloads; 1920 or 3840 pixels on the output's long edge.
- **Music:** local audio playlist, play/pause, skip, volume, and repeat. Music is played live and is not mixed into exported MP4s.

New installations start with **9 seconds, Strong motion, Varied movement, Fit with Black Bars, shuffle and fades on, full-quality unedited originals at 3840 pixels**, and videos and expansion off. Existing saved preferences are retained. Enabling expansion starts with 5% per edge and no extra zoom-out allowance unless those values were previously changed.

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

Builds are ad-hoc signed and not notarized. A downloaded prerelease may require macOS's normal user approval to open. Compatibility with future private framework revisions is not guaranteed.

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

This creates `dist/SpatialSlideshow-0.8.0-macOS-arm64.zip` and its SHA-256 file. It does not tag, publish, or upload anything. Set `SPATIAL_APP_OUTPUT` to build a separate release bundle without replacing a running development app. The archive contains the app, icon, and helper executables; Apple frameworks and models remain system dependencies.

[Architecture and research notes](Docs/RESEARCH.md) describe the working model routes and their limits. [Research probes](Research/README.md) preserve source-only diagnostics; no Apple binaries, disassembly, model weights, or decompiled implementations are included.
