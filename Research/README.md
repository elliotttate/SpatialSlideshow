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

For any inference or image probe, use only a user-supplied Trip album export. Diagnostic output can include local paths and should remain outside Git. The reusable expansion implementation is now `Sources/ExpandPhoto.swift`; duplicated trial scripts and personal review galleries were not retained.

The `Stubs/` directory contains the authored Swift/Objective-C declarations and text-based linker symbol tables required to call installed frameworks. System framework executables, model weights, decompiled method bodies, assembly dumps, and patched Photos app copies are not included. See [research findings](../Docs/RESEARCH.md) for the working routes and limitations.
