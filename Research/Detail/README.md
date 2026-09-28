# Full-resolution border detail (research only)

September 28, 2026. Not used by the app.

## Idea

Local FLUX backends generate the border near a 768-pixel source long edge, so the saved expanded still has a border roughly 5× softer than the full-resolution photograph. Photoshop 2026's local Remove path (its `AdbePM` "MetaCAF" engine) avoids a comparable problem: a 512-pixel CMGAN inpainting is followed by a masked 2× super-resolution model or used as the guide for full-resolution PatchMatch. `ExpansionDetailSynthesis.swift` applies that idea: the upscaled generation keeps its structure and color, and the photograph's missing high-frequency layer is copied from matching photograph locations (guided PatchMatch with EM voting, coarse to fine, deterministic).

## Result on stills

Six Trip expansions; border detail is mean Laplacian energy relative to the photograph interior.

| Sample | Canvas | Synthesis | Border detail before → after |
| --- | --- | ---: | --- |
| trip1 | 4234×5644 | 2.8 s | 0.33 → 0.59 |
| trip2 | 7996×5998 | 14.6 s | 0.31 → 0.78 |
| trip3 | 5644×4234 | 3.3 s | 0.59 → 0.95 |
| trip4 | 5644×4234 | 3.6 s | 0.51 → 0.76 |
| fog portrait | 2772×5124 | 2.3 s | 0.34 → 0.47 |
| rock-wall selfie | 3242×4324 | 2.1 s | 0.13 → 0.33 |

Timings were taken with system load average above 25. Generated structure was preserved, photograph pixels were untouched, and seam brightness steps were unchanged.

## Why it is not enabled

The expanded still is consumed only by `GenerateScene`. Apple's scene model returns a fixed 1,179,648 Gaussians (2 × 768²) and a 1536² depth map for every input size, and `RenderSlideshow` draws only those Gaussians. On a real Draw Things expansion rendered at 3840 px with 20% expansion and 35% zoom-out, border detail in the first frame was 3.51 without synthesis and 3.49 with it. The slideshow cannot show detail finer than the scene grid, so the step only added time and would have invalidated every cached still.

## Reproduce

```sh
xcrun swiftc -O -parse-as-library -target arm64-apple-macos27.0 Research/Detail/ExpansionDetailSynthesis.swift Research/Detail/DetailSynthesisProbe.swift -o build/research/DetailSynthesisProbe
```

The job JSON contains `canvas_size` [W, H]; `box` [x, y, w, h] of known photograph pixels; raw RGB8 `guide` (W×H upscaled generation), `original` and `degraded` (w×h photograph and its copy resized to model size and back); `output`; and optional `settings`. The last production-candidate settings were `coarse_iterations` 4, `middle_iterations` 1, `fine_iterations` 0 and `patch_radius` 3.
