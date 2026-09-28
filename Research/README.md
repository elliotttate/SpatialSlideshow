# Source-only research probes

These small diagnostics preserve the interface investigation that led to the app's direct model helpers. Build them with:

```sh
./Research/build_probes.sh
```

The build only compiles; it does not run a probe, load a model, or access Photos. Binaries go in ignored `build/research/`.

| Probe | Behavior when explicitly executed |
| --- | --- |
| `AssetProbe` | Queries installed spatial asset metadata and prints local model locations |
| `BaseProbe MODEL_URL [--joint]` | Attempts direct joint or FOV model loading from a supplied installed path |
| `ServiceProbe IMAGE [OUTPUT] [--in-process]` | Investigates the earlier service route; it may fail entitlement checks and is not the app's working backend |
| `InspectModels` | Loads installed cleanup models with the observed precompiled configuration and prints feature descriptions |
| `LinkCheck` | Checks the exported cleanup call signatures and prints Swift layout metadata without inference |
| `DumpRegistry` | Enumerates relevant runtime classes, selectors, and implementation locations without altering them |
| `RuntimeProbe FRAMEWORK...` | Enumerates classes/method signatures in supplied installed private frameworks |
| `ExtendCapabilityProbe` | Reads this process's OS-visible inference entitlement; no Photos access or model request |
| `ExtendProbe TRIP_EXPORT NEW_OUTPUT.png [RESOLUTION]` | Calls Photos' actual Extend pipeline with optional 1024/2048/3072/4096 resolution; this uses Apple's server model and currently fails its restricted entitlement check |

For any inference or image probe, use only a user-supplied Trip album export. Diagnostic output can include local paths and should remain outside Git. The reusable expansion implementation is now `Sources/ExpandPhoto.swift`; duplicated trial scripts and personal review galleries were not retained.

The standalone Extend probe remains entitlement-blocked. A separate `Extend/attach_jit.py` research harness now queues the call in original Apple-signed Photos and detaches. Actual Trip outputs and the app's optional backend have been verified with user-disabled SIP. See [Apple Extend](../Docs/APPLE_EXTEND.md) for the boundary between this experiment and normal app operation. No build adds restricted entitlements or changes OS policy, system files, or library photos.

The separately built [Photos-process experiment](../Docs/APPLE_EXTEND.md#photos-process-experiment) stages one Trip export and a one-shot bridge. It has an owned-process control and an explicit LLDB entry. The dylib route remains blocked by Photos' library validation; the verified app research backend uses the JIT expression route instead. `build_probes.sh` only compiles the standalone diagnostics and never attaches to Photos.

The `Stubs/` directory contains the authored Swift/Objective-C declarations and text-based linker symbol tables required to call installed frameworks. System framework executables, model weights, decompiled method bodies, assembly dumps, and patched Photos app copies are not included. See [research findings](../Docs/RESEARCH.md) for the working routes and limitations.
