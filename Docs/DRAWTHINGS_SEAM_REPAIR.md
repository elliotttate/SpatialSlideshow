# Draw Things seam and focus repair

September 27, 2026. Real-media QA used only Trip album images. All generation in this investigation stayed local; no Apple Photos Extend/cloud or paid API requests were made.

## Findings and change

The reported rock-wall selfie already had a blurred outer border and a rectangular join in its cached expanded PNG, before Apple Reframe or video rendering. The production prompt repeatedly mentioned optical blur, blurry backgrounds and focused foregrounds, even in negative instructions. Replacing it with the existing `seamless-scene` prompt removed the unwanted bokeh on this selfie and a second photo from the same scene. This is evidence for these samples, not a guarantee that every photo's focus will match.

A second problem was compositing: the old helper pasted the original back at model resolution before the final full-resolution feather. Its three-pixel feather therefore mixed mostly two resolutions of the source at the boundary, rather than blending generated context into it.

Draw Things processing revision 2 introduced the following changes:

- Asks for a wider view of the same scene, matching its camera, lighting, color, texture and focus, without emphasizing blur or bokeh.
- Lets the generation mask overlap the source by 12 model pixels.
- Retains generated context through an 18-model-pixel inner band, then blends to the full-resolution original with a smoothstep feather.
- Restores and verifies exact source pixels beyond that band. At the normal 768-pixel source long edge, the feather occupies about 2.3% of that dimension on each side. It scales with photo resolution and is capped for small inputs.
- Includes the new settings and compositor code in persistent still and clip identities. Older expanded stills and clips remain on disk but are not replayed for this processing revision.

The existing MLX backend keeps its three-pixel restoration path. No added inference pass, model download or broad image blur is required by the fix.

## Alternatives tested

On the reported selfie, narrow Gaussian bands with model-space half-widths 4, 8 and 12 pixels and blur sigma 1, 2 and 3 softened the cut but could leave a visible soft stripe. Local Apple Fast Clean Up was also tested with a masked 8-pixel band on each side of the join; it completed in approximately 4.8 seconds but produced a soft strip on the rock texture. These alternatives were not enabled in production. Retaining and feathering the generated overlap gave the better local result in this comparison.

## Validation and limits

The synthetic tests cover the actual gRPC mask, generated-overlap preservation through inference, reduction of a hard pixel step, exact source-interior restoration, output profiles, corrupted/incomplete caches and processing-identity invalidation. The shared compositor rejects a mismatch between the helper's restoration contract and the requested overlap.

The real comparison includes the reported rock-wall selfie, a neighboring selfie, a shallow-focus trail portrait and a wide sunset landscape, at 20% per edge, four steps, guidance 1, seed 8612 and source long edge 768. Source images for the two selfies were recovered from the preserved centers of their prior caches because temporary downloaded originals had already been cleaned up. Other samples are existing Trip exports. Photos library originals were never edited.

The four new expansions took 26.9, 26.4, 25.1 and 20.6 seconds respectively on the M3 Max, with the renderer already warm. All four reported maximum source-interior RGB error 0. The bundled expansion → Apple Reframe → movie integration check passed, including expanded-still reuse after a motion change and clip reuse from a separate process. Evidence: `build/tests/model-20260927-193218/pipeline-test.json`.

The seam is less conspicuous on the rock-wall samples and their new borders retain sharp rock detail. Generated rocks, clothing and other surfaces still need not be geometrically correct; a feather cannot reconstruct missing content. Shallow-focus boundaries remain a model limitation, so this is not an album-wide guarantee of matching depth of field.

Private, ignored evidence is in `build/drawthings-seam-fix/`: the before/after, prompt-only comparisons, Apple/blur/overlap experiments, four final expanded stills and their manifests, logs and synthetic-test results. Personal images are not included in this document or tracked in Git.

## Revision 3: continuous color and multiband seams

The user still reported hard lines after revision 2. A compositor error contributed: border color correction operated only outside the original rectangle, then raw generated pixels were restored inside the overlap. This reintroduced a color step at the boundary. Revision 3 carries the same correction through the generated overlap before restoring the exact interior.

A narrow feather also failed to hide broader lighting and contrast changes. The new compositor separates four frequency bands at model resolution, with Gaussian radii 2, 8 and 24. Fine detail joins inside the existing 18-pixel band; progressively lower frequencies transition outward by 8, about 21 and 64 model pixels. Only source illumination is extended into that outer transition, while generated fine texture is retained. The final photo is not globally blurred, and the full-resolution source interior remains exact. No additional inference is needed.

The Draw Things processing revision is 3 and color-matching revision is 2. Both expanded-still and rendered-clip identities include the changed helpers. Existing cache files remain intact, but revision 2 results are not reused by the new session. The shared MLX path defaults to zero generated overlap and retains its prior restoration behavior.

All 32 Python tests pass, including new all-four-boundary continuity, texture-preservation, exact-interior and far-exterior checks. Three local Trip expansions (sunlit portrait, rock-wall selfie and shallow-focus trail portrait) took 25.4, 29.8 and 29.6 seconds with a warm server. Each reported source-interior RGB error 0. Evidence is under `build/drawthings-seam-v3/`.

The bundled revision 3 expansion → Apple Reframe → movie integration check passed, including expanded-still reuse with changed motion, cache reuse in a separate process and strict bundle-signature verification. Evidence: `build/tests/model-20260927-202711/pipeline-test.json`. The updated Python helpers were copied into the existing app and its signature renewed; no native code changed for this revision.

The rock-wall and trail samples have a less conspicuous join. A controlled comparison also recomposited the exact same raw rock-wall generation with revision 2 and revision 3, isolating the compositor change from inference variation (`same-generation-compare.jpg`). The first sunlit-portrait trial still showed a faint tonal rectangle; its source was recovered from a revision 2 cache and included that revision's altered feather, so it is not a pristine-source comparison. A further trial cropped away the old 90-source-pixel feather before generation. This removes that contamination at the cost of a slightly narrower composition; its top transition is softer, but a broad tonal band remains perceptible in the smooth sky. Provenance and output are in `sun-portrait/clean-center-provenance.json` and `sun-portrait/clean-final/`.

Multiband blending cannot guarantee correct invented objects, scene geometry or depth of field. It reduces compositing discontinuities, rather than proving every expanded album photo is seamless.
