# First-launch audit

September 27, 2026. This audit covers 0.8.1 source, isolated runtime setup, and the release bundle. It does not establish compatibility with every Mac or macOS build.

## Portability changes

- The main app and five native helpers target Apple Silicon and macOS 27. Native dependency inspection found only Apple system libraries/frameworks. No Homebrew libraries or developer-checkout paths are required.
- Shipping source and bundle inspection found no personal home-directory paths, library asset IDs, credentials, personal demo, sample album, or model weights. Paths come from the current user's Application Support folder, system APIs, the app bundle, or explicit user choices. Pinned download URLs, model identifiers, system framework paths, and the deliberately Trip-only research guard remain intentional constants.
- Photos access is requested when browsing; denied access has recovery instructions. iCloud originals and videos permit network access and request full quality. Completed clips persist across launches. Successful file builds now discard their temporary Gaussian scenes while retaining the final movie and logs.
- Models & Downloads in Settings checks requirements and can prepare them before playback. Playback also invokes setup automatically. Setup supports progress, cancellation, retry, diagnostics, and disk-space checks.
- Normal setup needs no Python, Homebrew, compiler, Draw Things desktop app, or change to macOS security settings. Apple Photos Extend is hidden behind explicit research access for new installations. Existing research selections are retained.
- Live signed-app testing caught a missing Photos Library entitlement: Hardened Runtime denied PhotoKit without displaying a permission prompt, despite the usage-description string. The signing workflow now includes and verifies `com.apple.security.personal-information.photos-library` on the main app. Native model helpers receive no additional entitlements. This follows [Apple's Photos Library entitlement documentation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.personal-information.photos-library).

## Model readiness

| Component | 0.8.1 behavior | Verification and limits |
| --- | --- | --- |
| Apple Reframe | Resolve macOS's active registered model set, validate both model directories, and request missing assets through an expiring subscription owned by this app | Existing installed models verified. Missing/partial/ambiguous cases tested synthetically. macOS accepted an app-owned user-initiated subscription, but a fresh model download was not established on a clean Mac. If unavailable, offer Open Photos and clear next steps. |
| Apple Fast Clean Up | Same readiness path for the inpainting/refinement pair, only when this optional engine is enabled | Existing pair verified. Apple controls eligibility and acquisition; Photos may need to complete setup. Expansion is off by default. |
| Draw Things FLUX | Automatically install a pinned portable CPython, hash-locked Apple Silicon wheels, official server, and checksum-pinned model files | Fresh portable Python and dependency installation tested with a system-only PATH, then isolated registration against verified existing weights. No second 8.63 GB weight download was attempted on the nearly full development disk. Small synthetic transfers test interruption, resumption, and checksum failure. |
| MLX Klein FLUX | Automatically install the same portable CPython, its own hash-locked dependencies, and pinned Hugging Face model revisions | Both dependency sets resolve to Apple Silicon wheels. The incomplete previous MLX cache is rejected without replacing registration. Full fresh weight installation and MLX inference were not rerun. |
| Apple Photos Extend | Explicit research choice, still restricted to Trip and its separate Photos/LLDB setup | Not presented as normal first-run functionality. No cloud quota probes or security changes were made for this audit. |

A normal Developer ID app cannot invoke Apple's privileged foreground asset-download APIs. An accepted background subscription is not proof that Apple has downloaded a model. The app reports readiness only after the required assets become readable; otherwise it stops preparation once with an actionable setup message instead of failing every photo. It never substitutes a different Reframe model.

## Installer integrity and recovery

Portable Python is downloaded to staging, checked against a pinned byte count and SHA-256, and tested in isolated mode before registration. A valid receipt alone is insufficient: a damaged interpreter triggers replacement only after the replacement passes its checks. Setup uses wheel-only dependencies with hashes; no source compilation or developer tools are needed.

Managed environments validate locked versions, installed file hashes, imports, and `pip check` before installer reuse. Incomplete environments and damaged managed weights are preserved before repair; custom Python environments and custom model directories are not modified. Registration is atomic and happens only after verification. Cancelled Draw Things transfers resume owned partial files. All installer children stay in a cancellable process group.

Python bytecode is disabled before imports, so setup does not modify the signed app. Models, environments, logs, and server caches are outside the bundle. The local Draw Things server chooses another loopback port if its preferred or registered port is occupied; unrelated services are never stopped. Port changes do not change model/render fingerprints.

Model-download errors have their own wording rather than being mislabeled as iCloud failures. Native renderer failures include a readable error prefix so the UI can display their cause.

## Validation

- All **16 native synthetic suites passed**, including the production runtime installer and Apple asset resolver. These tests do not read a Photos library or invoke models.
- All **48 Python tests passed**, including **15 installer tests** and **11 Draw Things bridge tests**.
- The native installer passed **28 offline checks** and **40 explicit bootstrap checks**: fresh download into a path with spaces, TLS/imports, reuse, invalid receipt repair, broken interpreter repair, and staging cleanup.
- HelperProcess passed **18 checks**, including live setup progress and cancellation of an installer and its descendant resisting graceful termination.
- A clean Draw Things dependency environment installed using portable Python and a system-only PATH, then registered successfully against existing verified weights. A deliberately damaged package was repaired to its original verified bytes.
- A real foreign loopback listener remained running while the bridge selected another port. Tests cover safe persistence and refusal to overwrite changed, staged, or symlinked registrations.
- The notarized app's bundled installer registered an isolated runtime from a relocated path containing spaces, using the verified portable environment, existing weights, and a system-only PATH. Its signature stayed intact and no bytecode was written inside the bundle.
- Signed helpers passed Apple Clean Up and Draw Things expansion → Apple Reframe → movie tests on an exported Trip photo, including cache reuse in a second process. Settings visibly reported the installed Apple and Draw Things models as ready.
- The corrected signed app successfully loaded the Photos album browser after the entitlement fix. A temporary fresh bundle identity also loaded the library on this research-configured Mac, but its permission prompt was not captured. This is not confirmation of the initial permission dialog on an untouched Mac. The temporary identity did confirm default preferences: 9 seconds, varied movement, fit with black bars, and expansion off.
- Apple accepted the corrected 0.8.1 archive with no notarization issues. The extracted app has the required Photos entitlement, passes strict signature and stapled-ticket validation, and passes `syspolicy_check distribution`. Gatekeeper assessment on this development Mac also reports that security is disabled, so that result alone is not treated as proof of normal end-user enforcement.

Run the explicit network bootstrap check separately:

```sh
python3 Tests/run_runtime_installer_test.py --bootstrap-integration
```

Detailed local evidence stays under ignored `build/first-launch-audit/`, `build/portable-runtime-audit/`, and `build/tests/`. Model tests and any personal screenshots remain untracked.

## Remaining compatibility limits

Private Photos, Alchemist, Core ML specialization, and Gaussian-renderer APIs remain OS-specific. macOS 27 and Apple Silicon are necessary constraints, not proof that every supported Mac has the same assets or interfaces. A separate fresh Mac/account remains the strongest outstanding portability check. Isolating the runtime folder on this development Mac does not simulate Apple feature eligibility or a new Photos permission state.

Photos permission, iCloud availability, Apple feature eligibility, disk space, and memory can still prevent an operation. The app should explain those failures; notarization does not remove these requirements. Project real-media QA remains restricted to the Trip album.
