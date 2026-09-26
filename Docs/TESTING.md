# Testing

`./test.sh` builds the production components used by each check and generates synthetic assets from `ffmpeg` filters and Python-generated sine waves. It never copies an existing photo, opens an album, or requests PhotoKit authorization.

Requirements: Apple Silicon macOS 27, full Xcode with a macOS 27 SDK, Python 3, `ffmpeg`, and `ffprobe`. The full suite needs a logged-in WindowServer session and functional local audio decoding. Music tests play muted. Display-sleep tests create and release an ordinary process-scoped IOKit assertion; they do not modify system power preferences.

| Test | What it checks |
| --- | --- |
| `storage` | Full-storage detection, retries, cancellation, and status clearing |
| `preparation` | Slow-first bypass, eventual inclusion, bounded prefetch, failure, and cleanup |
| `motion` | Camera compatibility, expansion compensation, and zoom-out bounds |
| `cache` | Exact photo-cache identity and stable movement across process launches |
| `persistent-cache` | Replay variants, revision/expansion isolation, and process restart |
| `video-cache` | Synthetic SDR/HDR exports, orientation, audio, edits, cancellation, and restart |
| `playback` | Waiting repeats, fades/cuts, final-frame retention, pause, and cancellation |
| `displayed-playback` | Actual retained video layer readiness and prepared-photo shuffling |
| `navigation` | Whole-photo Previous/Next, history, pause preservation, and buffered clips |
| `fullscreen` | Custom control actions, layout, complete idle hiding, and accessibility |
| `music` | Local playlist advance/repeat, pause, invalid tracks, and preferences |
| `display-sleep` | Playback assertion lifecycle without changing system settings |

Run a subset with repeated `--only NAME` arguments. `--core` runs the first six checks. Reports are in `build/tests/reports/`; compiler/runtime logs are in `build/tests/logs/`. These outputs may include local paths and must not be committed. Synthetic fixture provenance is recorded in `build/tests/fixtures/provenance.json`.

## Real model and visual checks

The separate `Tests/run_model_test.py` requires an explicit `--album Trip` assertion and a path to a photo the user exported from that album. The script cannot independently verify album membership. It reads that file and exercises real installed Apple models, producing plain and expanded clips, checking cache separation and reuse after a process restart, and checking temporary work cleanup. It does not alter the original file or query the library.

```sh
./build_slideshow.sh
python3 Tests/run_model_test.py --album Trip /path/to/exported-trip-photo.heic
```

All real-media project QA is restricted to Trip. Do not check in test photos, scene buffers, rendered videos, private library IDs, or review screenshots. Compare outputs with the source for color, subject size, border artifacts, camera travel, fades, and the zoom-out override. Validate native fullscreen and the Settings window in the running app. Synthetic layer tests are not a substitute for that visual review.
