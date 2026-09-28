# Testing

`./test.sh` builds the production components used by each check and generates synthetic assets from `ffmpeg` filters and Python-generated sine waves. It never copies an existing photo, opens an album, or requests PhotoKit authorization.

Requirements: Apple Silicon macOS 27, full Xcode with a macOS 27 SDK, Python 3, `ffmpeg`, and `ffprobe`. The full suite needs a logged-in WindowServer session and functional local audio decoding. Music tests play muted. Display-sleep tests create and release an ordinary process-scoped IOKit assertion; they do not modify system power preferences.

| Test | What it checks |
| --- | --- |
| `storage` | Full-storage and offline detection, retries, cancellation, and status clearing |
| `helper-process` | Live output/progress, bounded timeout, termination of unresponsive children, cancellation, and retained failure logs |
| `preparation` | Slow-first bypass, eventual inclusion, bounded prefetch, failure, and cleanup |
| `motion` | Camera compatibility, expansion compensation, and zoom-out bounds |
| `cache` | Exact photo-cache identity and stable movement across process launches |
| `persistent-cache` | Replay variants, revision/expansion isolation, and process restart |
| `video-cache` | Synthetic SDR/HDR exports, orientation, audio, edits, cancellation, and restart |
| `playback` | Waiting repeats, fades/cuts, final-frame retention, pause, and cancellation |
| `displayed-playback` | Retained layer readiness, unseen cached-photo priority, producer deduplication, complete repeat rounds, newly ready items interrupting repeats, refreshed variants, and final-frame retention |
| `navigation` | Whole-photo Previous/Next, history, pause preservation, and buffered clips |
| `fullscreen` | Custom control actions, layout, complete idle hiding, and accessibility |
| `music` | Local playlist advance/repeat, pause, invalid tracks, and preferences |
| `display-sleep` | Playback assertion lifecycle without changing system settings |
| `native-extend-recovery` | Simulated cloud errors, rate-limit cooldowns, cancellation, and authorization failures |
| `apple-model-setup` | Missing, incomplete, unique, and ambiguous installed Apple model sets using synthetic directories |
| `runtime-installer` | Download integrity, environment isolation, installation locks, cancellation, and reuse without model downloads |

Run a subset with repeated `--only NAME` arguments. `--core` runs the first six checks. Reports are in `build/tests/reports/`; compiler/runtime logs are in `build/tests/logs/`. These outputs may include local paths and must not be committed. Synthetic fixture provenance is recorded in `build/tests/fixtures/provenance.json`.

The full native suite contains 16 checks. Run all Python suites with a Python environment containing NumPy and Pillow using `python -m unittest discover -s Tests -p 'test_*.py'`. This includes `test_runtime_setup.py`, which uses small local HTTP fixtures to test resumed downloads, integrity checks, registration preservation, process groups, and package repair without downloading model weights.

`python3 Tests/run_runtime_installer_test.py --bootstrap-integration` explicitly downloads the pinned 25 MB portable Python archive into a temporary directory with spaces and verifies TLS/imports, reuse, invalid receipt repair, and broken interpreter repair. Repairs download another copy. This needs network access but does not install model weights or access the Photos library. See [the first-launch audit](FIRST_LAUNCH_AUDIT.md) for the limits of isolated-runtime tests on a development Mac.

## Real model and visual checks

The separate `Tests/run_model_test.py` requires an explicit `--album Trip` assertion and a path to a photo the user exported from that album. The script cannot independently verify album membership. It reads that file and exercises real installed Apple models, producing plain and expanded clips, checking cache separation and reuse after a process restart, and checking temporary work cleanup. It does not alter the original file or query the library.

```sh
./build_slideshow.sh
python3 Tests/run_model_test.py --album Trip /path/to/exported-trip-photo.heic
# Requires the separately installed local FLUX runtime and models:
python3 Tests/run_model_test.py --album Trip --backend fluxKlein /path/to/exported-trip-photo.heic
# Requires the separately installed Draw Things runtime and models:
python3 Tests/run_model_test.py --album Trip --backend drawThingsFlux /path/to/exported-trip-photo.heic
# Research setup only: original Photos open, user-disabled SIP, Xcode tools.
# This invokes Apple's online Extend service, not local inference.
python3 Tests/run_model_test.py --album Trip --backend applePhotosExtend --percent 20 /path/to/exported-trip-photo.heic
```

All real-media project QA is restricted to Trip. Do not check in test photos, scene buffers, rendered videos, private library IDs, or review screenshots. Compare outputs with the source for color, subject size, border artifacts, camera travel, fades, and the zoom-out override. Validate native fullscreen and the Settings window in the running app. Synthetic layer tests are not a substitute for that visual review.

The FLUX integration check uses an isolated expanded-still cache, verifies backend separation, changes motion with inference explicitly disabled to prove expanded-still reuse, then checks rendered-clip reuse in a second process. It keeps the existing Apple Reframe and rendering stages. Review FLUX's generated border separately from the preserved source interior.

`Tests/test_klein_expansion.py` is a separate synthetic test suite for FLUX's border geometry, source-pixel preservation, incomplete/corrupted caches, and publication failure cleanup. Run it with the configured Klein Python executable (or Python with NumPy and Pillow); it neither loads models nor accesses personal photos.

`Tests/test_klein_color.py` checks generated-border tint correction and preservation of the original using synthetic images. Inspect actual generated surroundings and encoded frames too: the source-preservation check alone cannot establish border color continuity. Use `--percent 20` on the model test to exercise the maximum extension.

`Tests/test_drawthings_expansion.py` covers the Draw Things bridge using synthetic data. The real-model check above verifies the Draw Things → expanded still → Apple Reframe → rendered clip path and persistent reuse separately. Watch model cancellation and app termination during live QA; only the app-owned loopback server may be stopped.

The Draw Things suite also verifies the overlapping wire mask, preservation of generated edge context through inference, a smooth transition across a synthetic hard step, and exact full-resolution interior pixels after feathering. Color tests cover continuity across all four boundaries, retained fine border texture through the multiband lighting blend, exact source interiors and unchanged generated pixels beyond the blend. The shared compositor rejects mismatched restoration/overlap metadata. For visual QA compare sharply focused backgrounds, shallow-focus photos and backlit skies: a softer join does not prove that generated geometry or depth of field matches the source. When using a recovered cached center, record whether it already contains an older feather; do not treat that altered edge as an untouched original.

`python3 Tests/test_native_expansion.py` checks native Extend's original-Photos process guard, cache integrity, and cancellation bookkeeping without attaching or invoking a model. The optional native integration above uses an isolated cache, disables new inference while testing changed-motion reuse, and checks playback-cache reuse in a separate process. Actual 5% and 20% Trip runs passed on build 26A428; the original composited centers had identical decoded RGB hashes. Photos itself is never terminated by the helper.

`python3 Tests/run_tests.py --only native-extend-recovery` uses the actual observed PCC socket and device-rate-limit error shapes with a simulated clock. It verifies retries of the same photo, increasing network delays, persisted rate-limit cooldowns, cancellation during waiting, and no retry of authorization failures. It makes no model requests. During a live device quota denial, verify cached playback and the countdown without submitting additional probes before the cooldown.

### Draw Things prompt comparisons

Run `Scripts/compare_drawthings_prompts.py` with the managed Draw Things Python, an explicit Trip-only source manifest, `--prepare-helper`, and an output directory under `build/`. The manifest format is `{"album":"Trip","sources":{"sample-name":"/absolute/path/to/exported-photo"}}`; album membership must be verified before supplying it. The runner compares the previous blur-oriented prompt, neutral continuation, local-detail matching, and seamless scene continuation with the same seed, four steps, and 20% expansion. `--variant` selects a subset and `--long-edge` can isolate generation-resolution effects.

The runner writes an HTML comparison, full-resolution outputs, exact prompts, timings, source-preservation results, and a separate cache. It does not change app settings or production caches. Keep these personal outputs and manifests untracked. Include both a sharp scene and a photo with genuine shallow focus; sharper borders alone do not establish a better focus match. If the slideshow is processing at the same time, timings include waiting for its local renderer.
