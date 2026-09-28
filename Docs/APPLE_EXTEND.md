# Native Photos Extend investigation

Status on macOS 27 build 26A428, September 27, 2026: **native Extend now generates images when the request runs inside original Apple-signed Photos**. The user temporarily disabled SIP for this experiment. A standalone caller still fails authorization. The app now includes an opt-in Apple Photos Extend research backend, currently restricted to the Trip album. Fast Clean Up, Reframe, and local FLUX remain independent paths.

Four successful Trip requests have verified the mechanism: a 4032 × 3024 source expanded horizontally to 5376 × 3024 in 16.12 seconds; a detached request with 5% on every edge produced 4436 × 3328 in 15.63 seconds; the app helper produced the same dimensions in 16.61 seconds; the 20% app test produced 5646 × 4234 in 15.60 seconds. These are native-call timings, not total slideshow preparation times. Both app tests passed Reframe rendering, reuse of the expanded still after changing motion, and clip reuse in a separate process. Decoded RGB hashes of the source and composited center matched exactly at both 5% and 20%. Rendered frames were visually inspected for composition and color.

## Direct request path

Headless IDA Pro 9.3, runtime method metadata, and standalone probes establish this route:

```text
Photos UI PEOutfillRequest
  -> PhotoImaging PIADMOutfillRequest / PIGenerativeRequest
  -> PIADMOutfillGenerativeProcessor
  -> PIOutfillPipeline.applyOutfill(...)
  -> PhotosGenerativeServices.OutpaintADMPipeline
  -> VisualGeneration.ImageOutfillRequest(revision1)
  -> ModelManagerServices CreateSessionRequest
```

The input is the source image plus a generated edit mask, with separate left/right/top/bottom expansion distances, orientation, CIContext, cancellation callback, and error return. PhotosGenerativeServices supplies `baseImage` and `editMask` inputs. No prose prompt is supplied by that wrapper; the server's internal prompt is unknown. The default production use case is `VisualGeneration.PhotosEdit.Outfill.1p`.

The higher-level Neutrino rendering request ultimately calls the same PIOutfillPipeline in the caller's process. Wrapping the request in PEOutfillRequest does not provide another process's model authorization.

## Standalone caller: two server model routes tested

The exported `OutpaintADMPipeline.modelResolutionOverride` selects the normal or large-image configuration through the request's image specification. On this OS:

| Resolution | Model bundle | Observed result |
| --- | --- | --- |
| Production default, large image | `com.apple.fm.visual.server_diffusion_v1.outpainting_large_image` | Rejected at session creation, about 0.3 seconds |
| Explicit 1024 | `com.apple.fm.visual.server_diffusion_v1.outpainting` | Rejected at session creation, about 0.2 seconds |

The 1024 run was verified in ModelManager's own log to select the normal bundle. It was not another invocation of the large-image configuration. Both runs used the same exported Trip photograph and produced no output file. The implementation also maps 2048 to the normal bundle and 3072/4096 to large-image; those additional sizes were not separately run.

Both catalog policies reported empty `unentitledUseCases`, `entitlementOverride: nil`, and `alwaysAllowUnentitled: false`. The daemon reported failure to verify `com.apple.modelmanager.inference`. These are server-diffusion configurations; the traced code exposes no local weights route analogous to Reframe or Fast Clean Up.

`ModelEnvironment` offers PCC and custom/Bolt server endpoint choices. It is not a CPU/GPU/local-model switch. No internal endpoint was contacted as an alternate authorization route.

## Exact authorization boundary

ModelManager validates the real client's audit token with `SecTaskCreateWithAuditToken` and `SecTaskCopyValueForEntitlement`. A true Boolean inference entitlement satisfies its ordinary validation branch. That branch itself does not impose a separate Apple-signature test.

The OS separately controls who may carry the restricted entitlement. Fresh capability-only controls isolated this single key:

| Helper | Result |
| --- | --- |
| Ordinary ad-hoc helper, no restricted entitlement | Starts normally; SecTask reports no inference entitlement |
| Ad-hoc helper with only `com.apple.modelmanager.inference` | Killed before main; AMFI -424, restricted entitlements |
| Apple Development-signed helper with only that key | Killed before main; AMFI -413, no matching provisioning profile; the sole unsatisfied entitlement is inference |

Copying/re-signing Photos permits the earlier injected research host to launch with ordinary development entitlements, but does not preserve Apple's model entitlement. The successful Reframe and Clean Up integrations instead load their installed local models directly. Their success does not establish permission for the Extend server model.

The daemon has a development exception for a bundle policy whose override is `com.apple.developer.foundation-model-adapter`. Neither Extend bundle advertises that override. Changing a use-case string or the helper's bundle identifier does not supply an OS-attested capability.

## Alternate entry points inspected

- PhotosViewService has no model inference entitlement and is not an Extend broker.
- The Photos PCCService found in PhotoLibraryServicesCore implements image provenance processing, not Outfill.
- VisualGenerationInference is an internal ModelManager provider extension. Its extension point is not public and requires the inference-provider-manager capability.
- The installed Photos App Intents metadata exposes no Extend action.

This survey found no supported app-callable broker. The research backend below uses a debugger expression in original Photos, not a public API or native UI automation/export.

## Source-only reproduction

Build without running inference:

```sh
./Research/build_probes.sh
./build/research/ExtendCapabilityProbe
```

Explicitly test a user-supplied Trip export, using a new output path:

```sh
./build/research/ExtendProbe /absolute/path/to/trip-export.heic /absolute/path/to/new-output.png
./build/research/ExtendProbe /absolute/path/to/trip-export.heic /absolute/path/to/new-1024-output.png 1024
```

These commands request native server inference if the caller is authorized. The resolution override exists only for that process. The probe refuses existing output paths and does not edit the library or original source. The build does not add private entitlements, alter policy, patch system files, or change system security settings. Decompilation databases, platform binaries, raw logs, personal media, and local signing identities stay outside the repository.

## Photos-process experiment

The user authorized testing inside the original Apple-signed Photos process after a temporary SIP change. After restarting, `csrutil status` confirmed disabled SIP and debugger attachment succeeded. Loading the development-signed bridge library still failed: Photos is a platform binary and library validation rejects the non-platform dylib. SIP alone does not remove that separate restriction.

`JITRequest.expr` resolves the existing native APIs and executes one asynchronous Objective-C++ expression inside original Photos. It avoids loading our dylib. SecTask reported the real inference entitlement as true, and ModelManager logs showed the large-image outpainting request dispatched to `pcc-agent-client`. Actual generated PNGs confirmed success. The debugger can detach immediately after queueing; target expression allocations remain valid until the request completes. Two detached requests succeeded, including the app helper. No AMFI, boot-argument, daemon-policy, or system-binary changes were made.

The first attached request triggered a nonfatal `EXC_RESOURCE` memory high-watermark warning at 1600 MB. It completed after detachment. The interactive harness now recognizes that specific warning and resumes; queue-and-detach avoids debugger stop events during inference. Other unexpected stops remain errors. This private-framework integration is not a supported deployment technique.

The app helper serializes native requests, validates original Photos' executable and the Trip input hash, saves separate files in Photos' container cache, and polls the result after detaching. It decodes the source with the app's SDR sRGB preparation helper and restores the full-resolution original over the generated center. Completed stills have hash-checked persistent caches under `Expanded Photos/Apple Photos Extend`; motion changes reuse them. Cancellation requests the native callback and never terminates Photos. A subsequent request waits for previous native work to finish rather than overlapping it.

In **Settings → Photo Edge Expansion**, choose **Apple Photos Extend**. Photos must already be open, the temporary SIP-disabled setup must be active, and Xcode tools must be available. This mode uses Apple's online service. It is off by default and currently available only for Trip album playback; ordinary file builds reject it. The current default backend remains Fast Clean Up.

### Cloud failures and recovery

A subsequent Trip album run exposed two independent service failures. Photo 2 failed after 79.16 seconds with `PrivateCloudComputeError: networkFailure`, POSIX 57, "Socket is not connected". Its inference entitlement was true; later photos generated successfully. Apple subsequently returned `deniedDueToUserDeviceRateLimit` on several new requests. This is a service quota response, not evidence of a malformed source photo or a failed entitlement bridge.

The app now retains the current photo while retrying connection failures after 5, 15, 60, then 300 seconds. A device rate limit pauses new requests for 15 minutes; repeated denials extend that to 30 and 60 minutes. These are app-chosen retry delays, **not Apple's quota-reset schedule**. The VisualGeneration/ModelManager error reaching the app loses the underlying PCC retry-after metadata (see the verified quota investigation below). `Native Extend Service.json` persists the cooldown across launches. Stop remains responsive, and prepared clips keep playing. An explicit cache-only probe can reuse expanded stills during cooldown without submitting another model request. Full service errors remain in Diagnostics; the UI shows a short explanation and countdown. Changes to recovery leave the generation helpers and existing cache fingerprints unchanged.

### Verified quota policy, September 27, 2026

A read-only inspection of the active PCC daemon's `production/ratelimitmodel_v4.plist`, corroborated by unified logs and headless IDA analysis of PrivateCloudComputeDaemon on macOS 27 build 26A428, found these server-delivered `vault` policies on this Mac:

| Feature identifier | Request count | Rolling duration | Retry jitter |
| --- | ---: | ---: | ---: |
| `VisualGeneration.PhotosEdit.Outfill.1p` (Extend) | 10 | 86,400 s | 8,640 s |
| `VisualGeneration.PhotosEdit.Infill.1p` (cloud Clean Up) | 15 | 86,400 s | 8,640 s |
| `VisualGeneration.PhotosEdit.SpatialReframing.1p` (cloud Reframe) | 10 | 86,400 s | 8,640 s |
| `VisualGeneration.PhotosEdit` (shared Photos editing parent) | 60 | 86,400 s | 8,640 s |

Matching `Apple.Group1.*` policies have the same values; they are alternate scoped policies, not additional allowances. These are observed device policies, not universal or permanent published limits. Apple's [usage-limit guidance](https://support.apple.com/en-us/127901) says limits may vary by feature, request complexity, demand, and policy. Local Reframe and Fast Clean Up inference in this app do not use the PCC request path; cached playback also consumes no PCC requests.

The daemon logged `rate limit applied for rate with count=10, duration=86400.000000` at 18:38:16 EDT. Its request log contained exactly ten matching Extend submissions, from 16:25:07 through 18:37:47 EDT. This includes native Photos usage, earlier research tests, and the request that later failed with the network error. Thus ten submissions do not imply ten successful slideshow images. The current filter has no bundle restriction or resolution/workload-tag restriction; changing image size does not provide another allowance.

IDA function `0x28602B1E4` counts matching requests inside the duration and rejects when count reaches the configured limit. `0x2860346E8` and `0x286034BF8` show dot-delimited feature-prefix matching, so the parent Photos policy is shared. `0x28602FDDC` constructs the retry date from the oldest matching request in the window plus the duration and a random nonnegative fraction of the configured jitter. `0x286030708` generates a value in [0, 1); the date-add and date-subtract imports were independently resolved in a read-only owned-process symbol probe. A cached denial is honored until its retry date. The configuration's `ttlExpiration` is policy freshness, **not** the quota reset.

For the observed ten requests, the first 24-hour anniversary is September 28 at 16:25:07 EDT. The computed retry-after range is therefore approximately 16:25–18:49 EDT that day, depending on the daemon's selected jitter and any updated policy. This is a bounded estimate; the exact selected retry-after date was redacted from unified logs and was not recovered. The lower-level error carries `PrivateCloudComputeErrorRetryAfterDate` and `AppleIntelligenceRetryAfterDate`, but the current app's higher-level error does not preserve them. No quota state was reset, changed, or bypassed during this investigation, and no additional generation probes were submitted.

The new `Research/Extend/InProcessBridge.m` has no constructor or persistent listener. Explicitly calling `SpatialExtendStart` accepts one prepared Trip job, verifies that the executable is the original system Photos, records the host's OS-visible inference entitlement, and queues the native call on a background thread. The debugger then detaches so the host can execute normally. The bridge preserves native model settings and saves a separate PNG. The original library photo is never opened for writing.

The input is copied to an isolated UUID folder under Photos' own container cache so a Photos-host test need not gain access to arbitrary external files. The request records the source and bridge hashes. `result.json` reports queued/generating/failed/complete, PID, executable, entitlement, dimensions, and errors. A `cancel` file requests cancellation through the pipeline callback; that callback also imposes a five-minute deadline. This is cooperative cancellation, not a guarantee against a stalled framework call. The harness never terminates Photos to enforce the deadline.

Build and run the owned-process control:

```sh
bash Research/Extend/build_bridge.sh
python3 Research/Extend/prepare_bridge.py /absolute/path/to/trip-export.heic --album Trip --control
```

The bridge and control host are arm64e and use the existing local Apple Development identity without restricted entitlements. The control verified dynamic loading, asynchronous execution, fixture hashing, and the native request/error path. It correctly recorded `originalPhotos: false`, `inferenceEntitlement: false`, and the existing service rejection. A separate LLDB control verified the load/symbol/call expressions and that the Photos entry rejects a non-Photos host. These controls are **not** proof that original Photos will allow the library to load.

Prepare a Photos-host job without attaching:

```sh
python3 Research/Extend/prepare_bridge.py /absolute/path/to/trip-export.heic --album Trip
```

The pending directory is saved in ignored `build/research/extend-bridge/pending-photos-job.txt`, allowing the investigation to resume after a restart. After the user changes SIP in Recovery, first verify `csrutil status`, ensure Photos has no in-progress edit, and obtain its **current** PID. Then explicitly import the LLDB command and run it:

```text
command script import /absolute/path/to/SpatialSlideshow/Research/Extend/attach_bridge.py
spatial-extend-attach CURRENT_PHOTOS_PID /absolute/path/to/prepared/job
```

The dylib command refuses enabled or unreviewed custom SIP configurations, another executable, a changed bridge hash, or an already-started job. It records `attach-result.json` and detaches in a `finally` block. It now reaches library validation but cannot load the bridge into original Photos.

Use the verified expression route instead, with a fresh prepared job:

```text
command script import /absolute/path/to/SpatialSlideshow/Research/Extend/attach_jit.py
spatial-extend-jit-queue CURRENT_PHOTOS_PID /absolute/path/to/prepared/job
```

Poll the job's `result.json` for completion. A queued result or a successful detach is not proof of generation. `expanded.png`, dimensions, entitlement, and the native error or completion status are recorded independently. A `percentPerEdge` request value from 1 through 20 selects four-sided expansion; omitting it preserves the original horizontal-only research geometry. The ordinary app helper supplies this value from Settings.

Changing SIP requires Recovery; no script here changes it, AMFI, boot arguments, the sealed system volume, or system binaries. Apple's instructions cover [starting Recovery on Apple silicon](https://support.apple.com/en-us/102518) and [temporarily disabling and restoring SIP](https://developer.apple.com/documentation/security/disabling-and-enabling-system-integrity-protection). Reenable SIP in Recovery after the experiment. Loaded research code ends with the Photos process; no automatic relaunch or persistent injection is installed.
