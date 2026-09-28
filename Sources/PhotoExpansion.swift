import Foundation
import CryptoKit

enum KleinRuntime {
    static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Photos Spatial Slideshow", isDirectory: true)
    }
    static func pythonURL(override: String = "") -> URL? {
        let manager = FileManager.default
        let path: String
        if !override.isEmpty { path = override }
        else if let data = try? Data(contentsOf: support.appendingPathComponent("Klein Runtime/runtime.json")),
                let registration = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let registered = registration["python"] as? String { path = registered }
        else { path = support.appendingPathComponent("Klein Runtime/venv/bin/python").path }
        guard manager.isExecutableFile(atPath: path) else { return nil }
        // Keep the venv symlink: resolving it would lose its installed packages.
        return URL(fileURLWithPath: path)
    }
}

enum DrawThingsRuntime {
    static var root: URL { KleinRuntime.support.appendingPathComponent("Draw Things Runtime", isDirectory: true) }
    static func pythonURL() -> URL? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("runtime.json")),
              let registration = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = registration["python"] as? String,
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }
    private static let idleLock = NSLock()
    private static var idleStop: DispatchWorkItem?
    static func beginWork() {
        idleLock.lock(); defer { idleLock.unlock() }
        idleStop?.cancel(); idleStop = nil
    }
    static func finishWork() {
        idleLock.lock(); defer { idleLock.unlock() }
        idleStop?.cancel()
        let work = DispatchWorkItem { stopServer(idleOnly: true) }
        idleStop = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 600, execute: work)
    }
    static func stopServer(idleOnly: Bool = false) {
        guard let python = pythonURL(),
              let script = Bundle.main.resourceURL?.appendingPathComponent("ExpandPhotoDrawThings.py"),
              FileManager.default.isReadableFile(atPath: script.path) else { return }
        // The helper verifies process ownership and takes a nonblocking lock;
        // this cannot stop a user's Draw Things session or an active request.
        let process = Process()
        process.executableURL = python; process.arguments = [script.path, "--stop-server"]
        if idleOnly { process.arguments? += ["--idle-seconds", "600"] }
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}

/// Snapshot once per play/build so UI changes cannot mix processing settings.
struct PhotoExpansionConfiguration {
    let percent: Int
    let modelFingerprint: String
    var zoomOutPercent: Int = 0
    var backend: ExpansionBackend = .appleCleanup
    var kleinPythonURL: URL?
    var stillCacheRoot: URL = KleinRuntime.support.appendingPathComponent("Expanded Photos/FLUX.2 Klein", isDirectory: true)
    static let disabled = PhotoExpansionConfiguration(percent: 0, modelFingerprint: "")
    var enabled: Bool { percent > 0 }
    var allowedZoomOutPercent: Int { min(max(0, zoomOutPercent), min(20, max(0, percent)) * 2) }

    func cacheIdentity(_ sourceIdentity: String) -> String {
        guard enabled else { return sourceIdentity } // Preserve existing caches exactly.
        // Version the expanded framing separately: old clips reveal the whole
        // generated canvas and must not be replayed after the composition fix.
        let namespace: String
        switch backend {
        case .appleCleanup: namespace = "apple-cleanup-motion-v2"
        case .fluxKlein: namespace = "flux-klein-motion-v1"
        case .drawThingsFlux: namespace = "draw-things-flux-motion-v1"
        case .applePhotosExtend: namespace = "apple-photos-extend-motion-v1"
        }
        let baseline = sourceIdentity + "|\(namespace)|\(percent)|\(modelFingerprint)"
        // Zero retains the existing original-composition cache. Nonzero
        // allowances isolate both exact hits and waiting replay variants.
        return allowedZoomOutPercent == 0 ? baseline : baseline + "|zoom-out-\(allowedZoomOutPercent)"
    }

    static func resolve(enabled: Bool, percent: Int, zoomOutPercent: Int = 0,
                        backend: ExpansionBackend = .appleCleanup, kleinPythonPath: String = "",
                        tools: URL, albumTitle: String? = nil, cancelled: () -> Bool = { false },
                        automaticallyInstall: Bool = false, progress: (String) -> Void = { _ in }) throws -> Self {
        guard enabled else { return .disabled }
        if backend == .applePhotosExtend {
            guard albumTitle == "Trip" else {
                throw failure("The Apple Photos Extend backend is currently enabled only for the Trip album.")
            }
            let python = URL(fileURLWithPath: "/usr/bin/python3")
            let script = tools.appendingPathComponent("ExpandPhotoNative.py")
            let prepare = tools.appendingPathComponent("PrepareExpansionPhoto")
            let log = FileManager.default.temporaryDirectory.appendingPathComponent("Native-Extend-check-\(UUID().uuidString).log")
            defer { try? FileManager.default.removeItem(at: log) }
            try HelperProcess.run(python, arguments: [script.path,"--check","--prepare-helper",prepare.path], log: log,
                                  environment: ProcessInfo.processInfo.environment, stage: "Checking Apple Photos Extend research setup",
                                  timeout: 30, cancelled: cancelled, progress: { _ in })
            let fingerprint = SHA256.hash(data: try Data(contentsOf: log)).map { String(format: "%02x", $0) }.joined()
            return Self(percent: min(20,max(1,percent)), modelFingerprint: fingerprint,
                        zoomOutPercent: zoomOutPercent, backend: backend, kleinPythonURL: python,
                        stillCacheRoot: KleinRuntime.support.appendingPathComponent("Expanded Photos/Apple Photos Extend", isDirectory: true))
        }
        if backend != .appleCleanup {
            let drawThings = backend == .drawThingsFlux
            let availablePython = automaticallyInstall
                ? try RuntimeInstaller.ensure(backend: backend, tools: tools, override: kleinPythonPath, cancelled: cancelled, progress: progress)
                : (drawThings ? DrawThingsRuntime.pythonURL() : KleinRuntime.pythonURL(override: kleinPythonPath))
            guard let python = availablePython else {
                throw failure("\(backend.title) needs its local models. Start playback or choose Download Models in Settings to install them automatically.")
            }
            let script = tools.appendingPathComponent(drawThings ? "ExpandPhotoDrawThings.py" : "ExpandPhotoKlein.py")
            let prepare = tools.appendingPathComponent("PrepareExpansionPhoto")
            guard FileManager.default.isReadableFile(atPath: script.path),
                  FileManager.default.isExecutableFile(atPath: prepare.path) else {
                throw failure("The FLUX expansion helper is missing. Rebuild or reinstall Spatial Slideshow.")
            }
            let log = FileManager.default.temporaryDirectory.appendingPathComponent("Expansion-check-\(UUID().uuidString).log")
            defer { try? FileManager.default.removeItem(at: log) }
            var environment = ProcessInfo.processInfo.environment
            environment["HF_HUB_OFFLINE"] = "1"; environment["HF_HUB_DISABLE_XET"] = "1"
            try HelperProcess.run(python, arguments: [script.path, "--check", "--prepare-helper", prepare.path], log: log,
                                  environment: environment, stage: "Checking \(backend.title) installation",
                                  timeout: 60, cancelled: cancelled, progress: { _ in })
            guard let identity = try JSONSerialization.jsonObject(with: Data(contentsOf: log)) as? [String: Any] else {
                throw failure("\(backend.title) could not verify its local installation. Open Setup Help in Settings.")
            }
            var hash = SHA256()
            hash.update(data: try JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys]))
            for file in [script, prepare] { hash.update(data: try Data(contentsOf: file, options: .mappedIfSafe)) }
            return Self(percent: min(20, max(1, percent)),
                        modelFingerprint: hash.finalize().map { String(format: "%02x", $0) }.joined(),
                        zoomOutPercent: zoomOutPercent, backend: backend, kleinPythonURL: python,
                        stillCacheRoot: KleinRuntime.support.appendingPathComponent(drawThings ? "Expanded Photos/Draw Things FLUX" : "Expanded Photos/FLUX.2 Klein", isDirectory: true))
        }
        let helper = tools.appendingPathComponent("ExpandPhoto")
        let manager = FileManager.default
        guard manager.isExecutableFile(atPath: helper.path) else {
            throw failure("The photo expansion helper is missing. Rebuild Spatial Slideshow.")
        }
        let assetRoot = URL(fileURLWithPath: "/System/Library/AssetsV2/com_apple_MobileAsset_UAF_Photos_MagicCleanup/purpose_auto")
        let assets = (try? manager.contentsOfDirectory(at: assetRoot, includingPropertiesForKeys: nil)) ?? []
        let candidates = assets.filter { $0.pathExtension == "asset" }.map { $0.appendingPathComponent(".AssetData") }.filter {
            manager.fileExists(atPath: $0.appendingPathComponent("inpainting.mlmodelc").path) &&
            manager.fileExists(atPath: $0.appendingPathComponent("refinement.mlmodelc").path)
        }
        guard candidates.count == 1, let model = candidates.first else {
            throw failure("Apple’s Fast Clean Up models are unavailable. Open Clean Up in Photos to download them, or turn off Expand Photo Edges.")
        }
        var identity = "cleanup-composite-v1|" + ProcessInfo.processInfo.operatingSystemVersionString + "|" + model.path
        for file in [helper, model.appendingPathComponent("metadata.json"),
                     model.appendingPathComponent("inpainting.mlmodelc/coremldata.bin"),
                     model.appendingPathComponent("refinement.mlmodelc/coremldata.bin")] {
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            identity += "|" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        let fingerprint = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return Self(percent: min(20, max(1, percent)), modelFingerprint: fingerprint, zoomOutPercent: zoomOutPercent)
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "PhotoExpansion", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

extension RenderSession {
    func expandedInput(_ input: URL, configuration: PhotoExpansionConfiguration, directory: URL,
                       tools: URL, progress: (String) -> Void) throws -> URL {
        guard configuration.enabled else { return input }
        try check()
        let log = directory.deletingLastPathComponent().appendingPathComponent(directory.lastPathComponent + ".log")
        let stage = "\(configuration.backend.title) · expanding \(configuration.percent)% per edge"
        if configuration.backend == .applePhotosExtend {
            let python = URL(fileURLWithPath: "/usr/bin/python3")
            let arguments = [tools.appendingPathComponent("ExpandPhotoNative.py").path,
                    input.path, directory.path, String(configuration.percent),
                    "--prepare-helper", tools.appendingPathComponent("PrepareExpansionPhoto").path,
                    "--cache-root", configuration.stillCacheRoot.path]
            // A saved still can be used even while Apple is throttling new work.
            // This probe is explicitly forbidden from starting model inference.
            var cacheEnvironment = ProcessInfo.processInfo.environment
            cacheEnvironment["SPATIAL_NATIVE_EXTEND_CACHE_ONLY"] = "1"
            do {
                try HelperProcess.run(python, arguments: arguments, log: log,
                    environment: cacheEnvironment, stage: "Checking saved Apple Photos Extend image",
                    timeout: 30, cancelled: { self.isCancelled }, progress: { _ in })
                progress("Reusing saved Apple Photos Extend image")
            } catch is CancellationError { throw CancellationError() }
            catch {
                guard ((error as NSError).userInfo["output"] as? String)?.contains("No matching cached Apple Photos Extend image.") == true else {
                    throw NativeExtendRecovery.userError(error)
                }
                try NativeExtendRecovery.run(check: check, progress: progress) {
                    try run(python, arguments, log: log, stage: stage, timeout: 660, slowAfter: 60, progress: progress)
                }
            }
        } else if configuration.backend != .appleCleanup {
            let drawThings = configuration.backend == .drawThingsFlux
            guard let python = configuration.kleinPythonURL else {
                throw NSError(domain: "PhotoExpansion", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(configuration.backend.title) has no configured runtime. Open Setup Help in Settings."])
            }
            if drawThings { DrawThingsRuntime.beginWork() }
            defer { if drawThings { DrawThingsRuntime.finishWork() } }
            try run(python, [tools.appendingPathComponent(drawThings ? "ExpandPhotoDrawThings.py" : "ExpandPhotoKlein.py").path,
                             input.path, directory.path, String(configuration.percent),
                             "--prepare-helper", tools.appendingPathComponent("PrepareExpansionPhoto").path,
                             "--cache-root", configuration.stillCacheRoot.path],
                    log: log, environment: ["HF_HUB_OFFLINE": "1", "HF_HUB_DISABLE_XET": "1", "PYTHONUNBUFFERED": "1"],
                    stage: stage, timeout: drawThings ? 360 : 1800, slowAfter: drawThings ? 90 : 600, progress: progress)
        } else {
            try run(tools.appendingPathComponent("ExpandPhoto"), [input.path, directory.path, String(configuration.percent)],
                    log: log, stage: stage, progress: progress)
        }
        let expanded = directory.appendingPathComponent("expanded.png")
        guard FileManager.default.fileExists(atPath: expanded.path),
              FileManager.default.fileExists(atPath: directory.appendingPathComponent("expansion.json").path) else {
            throw NSError(domain: "PhotoExpansion", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(configuration.backend.title) did not finish expanding this photo."])
        }
        return expanded
    }

    func attachExpansionMetadata(input: URL, configuration: PhotoExpansionConfiguration, scene: URL) throws {
        guard configuration.enabled else { return }
        let data = try Data(contentsOf: input.deletingLastPathComponent().appendingPathComponent("expansion.json"))
        guard var metadata = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "PhotoExpansion", code: 3, userInfo: [NSLocalizedDescriptionKey: "The expanded photo metadata is invalid."])
        }
        metadata["zoom_out_percent"] = configuration.allowedZoomOutPercent
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
            .write(to: scene.appendingPathComponent("expansion.json"), options: .atomic)
    }
}
