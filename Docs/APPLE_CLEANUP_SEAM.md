# Apple Fast Clean Up border color and seam

October 11, 2026. Real-media checks used only Trip album exports. All inference ran locally with the installed Photos Clean Up models; no Apple Extend, cloud, or paid API request was made.

## Problem

Apple Fast Clean Up expansions often had a generated border that did not match the photograph's color, and a visible hard line where the border started. Measured on Trip samples at 20% per edge, the mean color step across the join was 4–6 levels (0–255) on most sides and up to 11 on one, before any seam defects.

## Findings

**The pipeline reads the pixels under its mask as a prior.** `InpaintGANPipeline.renderTile` does not blank the masked region. The helper previously filled the new border with flat 50% gray, and the fill color changed both the color and the content of the result. Same photo, same mask, 1024-pixel source long edge; the table lists the largest per-channel mean step between the 4 model pixels inside and outside the join:

| Fill under the mask | Left | Right | Top | Bottom |
| --- | ---: | ---: | ---: | ---: |
| Gray 50% (previous) | 4.9 | 4.7 | 5.3 | 6.6 |
| Black | 5.9 | 9.9 | 6.1 | 9.5 |
| White | 21.0 | 12.3 | 2.7 | 23.3 |
| Edge-replicated source | 1.7 | 1.4 | 6.2 | 2.3 |
| Mirrored source | 1.8 | 1.1 | 5.4 | 2.2 |

Black and white fills also produced dark or bright intrusions in the generated content. Edge replication and mirroring continued texture plausibly; replication is simpler and avoids mirrored structures, so the helper now uses it. The remaining top-edge step on this sample is a real brightness gradient toward the sky.

**Effective resolution is fixed.** The installed inpainting model takes a 512×512 four-channel input and the refinement model 1024×1024, and inference took 0.4–0.85 seconds whether the canvas was 718 or 2868 pixels wide. The generated border is therefore always soft relative to the full-resolution original, which made the previous 3-model-pixel linear feather read as a line.

**Per-edge high-resolution tiles were rejected.** Running the pipeline on square tiles along each edge, either with edge-replicated fill or with the whole-canvas result as a prior, produced sharper texture but also hallucinated black voids and face-like shapes where a tile had context on only one side. The whole-canvas pass is blurrier but coherent, so it stays.

## Change

The helper `ExpandPhoto` now:

- fills the model canvas under the mask with the replicated edge of the photograph instead of gray;
- lets the mask overlap the photograph by 12 model pixels so the model repaints the join;
- matches the generated border to the photograph in perceptual OKLab with the same per-side, smoothed, clipped correction the FLUX helpers use, carried continuously through the overlap;
- joins generated and source content with a four-band Laplacian blend at model resolution (Gaussian radii 2, 8 and 24): fine detail hands over inside a 16-model-pixel band, lighting changes spread up to 64 model pixels into the new border, and nothing outside that band is blurred;
- restores the full-resolution original beyond the band with a smoothstep feather, then re-reads the saved PNG and refuses to publish unless the protected interior is pixel-exact.

At the normal 1024-pixel model long edge the inner band is about 1.6% of the long edge per side. The compositor is `Sources/ExpansionCompositor.swift`, shared with the synthetic `expansion-compositor` test. The Apple expansion identity changed to `cleanup-composite-v2`, so earlier Apple expansions and clips are regenerated when needed; existing files are left in place.

## Results and limits

On four Trip photos at 5% and 20% the hard line and the crisp rectangle at each corner are no longer visible at native resolution; joins become soft transitions over the band. A warm run of the helper on a 4032×3024 photo took about 3 seconds in total, including 0.6 seconds of seam compositing; the first run after launch adds model loading. All five checked outputs reported a protected-interior error of 0.

The generated border is still the model's low-resolution guess. Objects cut by the photograph's edge can continue implausibly, large expansions under subjects stay smeared, and the regenerated overlap can soften detail within the band. A visible brightness or focus difference between a sharp subject and the softer border remains possible; the blend hides the step, not the difference in detail.

Research probes used for this comparison are under `Research/Cleanup/`; see `Research/README.md`. Personal review images were not retained in the repository.
