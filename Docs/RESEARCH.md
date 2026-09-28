# Architecture and model research

These notes describe observations from the project's macOS 27 development installation. They are not a promise that Apple's private interfaces will remain stable.

## Reframe

The first route used `AlchemistService.ALCService` and encountered a restricted entitlement check. The working helper instead uses the exported `AlchemistBase.ALCBasePipeline` interface directly with the Mac's registered spatial asset directory:

```text
/System/Library/AssetsV2/com_apple_MobileAsset_UAF_Photos_SpatialPhotosRelive/purpose_auto/<asset>.asset/.AssetData/
```

The joint predictor and FOV predictor are loaded in place. Earlier restore-image copies failed to load on the tested machine; using the registered installation succeeded. This establishes a working direct route on that installation, not the exact reason for every internal ANE loading decision. The service route remains a separate, entitlement-gated interface.

`GenerateScene` color-manages the input, runs the actual predictor, and saves the returned Gaussian buffers plus a manifest. `RenderSlideshow` passes those buffers to `CoreRE3DGSFoundation`'s `GSAsset`, `GSSorter`, and `GSRenderer`, then records the camera animation using AVFoundation. This creates depth-dependent foreground/background motion rather than a flat image pan.

The camera uses a foreground-aware depth estimate so distant sky or fog cannot produce excessive travel. Source aspect ratio, reverse-Z projection, texture orientation, and matching video color tags are handled by the project's renderer adapter.

## Fast Clean Up as optional edge expansion

The app's `ExpandPhoto` helper uses `PhotosGenerativeServices.InpaintGANPipeline`, loading installed inpainting and refinement models from:

```text
/System/Library/AssetsV2/com_apple_MobileAsset_UAF_Photos_MagicCleanup/purpose_auto/<asset>.asset/.AssetData/
```

The observed Photos loading route uses `MLModelConfiguration.usePrecompiledE5Bundle` for the installed specialized models. Matching that configuration with `.all` compute units allowed direct local loading on the tested Mac. The helper builds an added-border mask and calls the exported image pipeline; it does not reconstruct Apple's internal preprocessing implementation.

The generated result is materialized once, resized to the output canvas, and composited with the full-resolution color-managed original, retaining its interior with a narrow seam blend. A manifest records the extra area for the camera. Expansion adds room to move while camera framing compensates for the larger canvas. The optional zoom-out allowance lets the animation deliberately reveal more of the generated border.

Generation can blur or invent details at the edges, especially at larger amounts. The Photos library is never edited. Generated images, scene buffers, and output clips remain local application data.

## Native Photos Extend

The [native Photos Extend investigation](APPLE_EXTEND.md) now includes successful original-Photos generation through a one-shot debugger expression, with SIP temporarily disabled by the user. The app offers this as an optional Trip-only research backend. Its request uses Apple's online Extend service and real Photos entitlement; standalone helpers remain blocked. Fast Clean Up above remains the local default.

## Color and caches

Input orientation and embedded color profiles are respected. HDR still images are tone-mapped to SDR, then converted to sRGB before inference. The Gaussian renderer operates in linear color; video output is matched to the Rec.709 metadata written to the MP4. Still-image output is SDR. Album videos use a separate export/cache route that preserves source timing and, when passthrough is supported, resolution, orientation, audio, and color tags.

Completed clips are indexed by source identity/edit revision and relevant settings. Motion assignment remains stable across shuffled album order. Expansion identities additionally include the helper/model/OS revision, padding amount, camera revision, and nonzero zoom-out allowance. This prevents old wide framing from silently satisfying corrected settings. Working directories are temporary; final photo/video caches persist.

## Portability limits

- Private framework names, Swift ABI signatures, model filenames, and the system asset root layout were observed on macOS 27. An OS update may require source changes.
- The `.swiftinterface`, `.tbd`, and Objective-C headers in this repository are declaration/linking adapters. They contain no Apple executable implementation.
- Cleanup currently requires one unambiguous installed inpainting/refinement pair. Multiple matching revisions cause a clear failure rather than selecting an arbitrary pair.
- Reframe's joint and FOV models are registered in separate installed assets. Discovery requires one of each predictor; ambiguous installations fail explicitly rather than depending on directory order. Assets are used in place; copying or repackaging them is not a supported setup method.
- Required assets depend on what Photos has installed and what the Mac supports. They are not downloaded by the build script.
- Local builds are ad-hoc signed. Published release downloads are Developer ID signed and notarized, with a stapled ticket. Local tests do not establish compatibility across all Macs or future private-framework revisions.

The source-only probes under `Research/` preserve the useful interface and loader checks. Historical copied app bundles, injection experiments, compiler caches, model weights, assembly dumps, and personal review pages are intentionally outside this project.
