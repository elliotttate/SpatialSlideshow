import Foundation
import Photos
import CryptoKit
import UniformTypeIdentifiers

enum PhotoSource {
    case file(URL)
    case library(PHAsset)
    var isLibraryVideo: Bool {
        if case .library(let asset) = self { return asset.mediaType == .video }
        return false
    }
    var cacheIdentity: String {
        switch self {
        case .file(let url):
            // URL resource values can retain metadata across repeated reads.
            // Read fresh attributes so edits during this session invalidate clips.
            let values = try? FileManager.default.attributesOfItem(atPath: url.path)
            let modified = (values?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (values?[.size] as? NSNumber)?.intValue ?? 0
            return "\(url.path)|\(modified)|\(size)"
        case .library(let asset): return "\(asset.localIdentifier)|\(asset.modificationDate?.timeIntervalSince1970 ?? 0)"
        }
    }
}

final class RenderSession {
    private let lock = NSLock()
    private var stopped = false
    private var process: Process?
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func check() throws { if isCancelled { throw CancellationError() } }
    func cancel() {
        lock.lock(); stopped = true
        if let process, process.isRunning { process.terminate() }
        lock.unlock()
    }
    func run(_ executable: URL, _ arguments: [String], log: URL, environment overrides: [String: String] = [:]) throws {
        let task = Process(); task.executableURL = executable; task.arguments = arguments
        var environment = ProcessInfo.processInfo.environment; environment["SPATIAL_NO_STILLS"] = "1"; environment.merge(overrides) { _, new in new }; task.environment = environment
        let pipe = Pipe(); task.standardOutput = pipe; task.standardError = pipe
        lock.lock()
        if stopped { lock.unlock(); throw CancellationError() }
        do { try task.run(); process = task; lock.unlock() }
        catch { lock.unlock(); throw error }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        lock.lock(); process = nil; lock.unlock()
        try data.write(to: log)
        try check()
        guard task.terminationStatus == 0 else {
            throw NSError(domain: "SpatialSlideshow", code: Int(task.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String((String(data: data, encoding: .utf8) ?? "Render failed").suffix(2400))])
        }
    }
    func export(_ source: PhotoSource, version: PhotoVersion = .current, into directory: URL, progress: @escaping (String) -> Void = { _ in }) throws -> URL {
        try check()
        if case .file(let url) = source { return url }
        guard case .library(let asset) = source else { fatalError() }
        let condition = NSCondition()
        var finished = false, data: Data?, format: String?, failure: Error?
        var lastPercent = -1
        let started = Date()
        var lastUpdate = started
        let options = PHImageRequestOptions()
        options.version = version == .original ? .original : .current
        options.deliveryMode = .highQualityFormat; options.isNetworkAccessAllowed = true
        progress("Loading full-quality photo from Photos…")
        options.progressHandler = { value, _, stop, _ in
            if self.isCancelled { stop.pointee = true; return }
            let percent = min(100, max(0, Int(value * 100)))
            condition.lock()
            let changed = !finished && percent != lastPercent
            lastPercent = percent
            if changed { lastUpdate = Date() }
            condition.unlock()
            if changed { progress("Downloading full-quality photo from iCloud · \(percent)%") }
        }
        let manager = PHImageManager.default()
        let request = manager.requestImageDataAndOrientation(for: asset, options: options) { imageData, uti, _, info in
            condition.lock()
            guard !finished else { condition.unlock(); return }
            data = imageData; format = uti; failure = info?[PHImageErrorKey] as? Error
            finished = true; condition.broadcast(); condition.unlock()
        }
        let deadline = started.addingTimeInterval(300)
        condition.lock()
        while !finished && !isCancelled && Date() < deadline {
            _ = condition.wait(until: Date().addingTimeInterval(0.2))
            if !finished && Date().timeIntervalSince(lastUpdate) >= 5 {
                let elapsed = Int(Date().timeIntervalSince(started))
                let phase = lastPercent < 0
                    ? "Waiting for Photos / iCloud to provide full quality · \(elapsed)s"
                    : "Downloading full quality · \(lastPercent)% · \(elapsed)s"
                lastUpdate = Date()
                condition.unlock(); progress(phase); condition.lock()
            }
        }
        let bytes = data, type = format, error = failure, complete = finished
        finished = true // Ignore a late callback after timeout/cancellation.
        condition.unlock()
        if isCancelled || !complete { manager.cancelImageRequest(request) }
        try check()
        guard let bytes, !bytes.isEmpty else {
            throw error ?? NSError(domain: "SpatialSlideshow", code: 2, userInfo: [NSLocalizedDescriptionKey: complete ? "This photo could not be loaded from Photos." : "Downloading this photo timed out."])
        }
        let ext = type.flatMap { UTType($0)?.preferredFilenameExtension } ?? "heic"
        let url = directory.appendingPathComponent("input.\(ext)")
        try bytes.write(to: url, options: .atomic)
        return url
    }
    func cachedClip(_ source: PhotoSource, seconds: Double, motion: Double, longEdge: Int, motionPattern: Int, version: PhotoVersion, root: URL, expansion: PhotoExpansionConfiguration = .disabled) -> URL? {
        if source.isLibraryVideo { return cachedVideoClip(source, version: version, root: root) }
        let record = CachedClipRecord(sourceIdentity: expansion.cacheIdentity(source.cacheIdentity), version: version, seconds: seconds, motion: motion, longEdge: longEdge, motionPattern: motionPattern)
        let output = ClipCacheCatalog.cacheDirectory(root: root).appendingPathComponent(record.filename)
        let values = try? output.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true, (values?.fileSize ?? 0) > 0 else { return nil }
        try? ClipCacheCatalog.record(record, root: root)
        return output
    }
    func clipCacheURL(_ source: PhotoSource, seconds: Double, motion: Double, longEdge: Int, motionPattern: Int, version: PhotoVersion, root: URL, expansion: PhotoExpansionConfiguration = .disabled) -> URL {
        if source.isLibraryVideo { return VideoClipCache.url(sourceIdentity: source.cacheIdentity, version: version, root: root) }
        let filename = ClipCacheCatalog.filename(sourceIdentity: expansion.cacheIdentity(source.cacheIdentity), version: version.rawValue, seconds: seconds, motion: motion, longEdge: longEdge, motionPattern: motionPattern)
        return ClipCacheCatalog.cacheDirectory(root: root).appendingPathComponent(filename)
    }
    func cachedReplayClips(_ sources: [PhotoSource], seconds: Double, motion: Double, longEdge: Int, patterns: [Int], version: PhotoVersion, root: URL, expansion: PhotoExpansionConfiguration = .disabled, progress: @escaping (String) -> Void = { _ in }) throws -> [(URL, Int)] {
        try check()
        let catalog = try ClipCacheCatalog(root: root, check: check)
        defer { catalog.saveRecoveryIndex() }
        var result: [(URL, Int)] = [], seen: Set<String> = []
        var lastProgress = Date.distantPast
        for (index, source) in sources.enumerated() {
            try check()
            let identity = source.isLibraryVideo ? source.cacheIdentity : expansion.cacheIdentity(source.cacheIdentity)
            guard seen.insert(identity).inserted else { continue }
            if source.isLibraryVideo {
                if let url = cachedVideoClip(source, version: version, root: root) { result.append((url, index)) }
                continue
            }
            if Date().timeIntervalSince(lastProgress) >= 0.25 {
                progress("Finding previously rendered photos · \(index + 1) of \(sources.count)")
                lastProgress = Date()
            }
            let pattern = patterns.indices.contains(index) ? patterns[index] : 0
            // Expanded clips have had sidecars from their first release. Do not
            // enumerate years of legacy plain-photo settings for every new
            // expansion amount while the album waits to start.
            if let url = try catalog.replay(sourceIdentity: identity, seconds: seconds, motion: motion, longEdge: longEdge, motionPattern: pattern, version: version, root: root, recoverUnindexed: !expansion.enabled, check: check) {
                result.append((url, index))
            }
        }
        try check()
        return result
    }
    func clip(_ source: PhotoSource, seconds: Double, motion: Double, longEdge: Int, motionPattern: Int, version: PhotoVersion, root: URL, tools: URL, expansion: PhotoExpansionConfiguration = .disabled, preparedInput: URL? = nil, progress: @escaping (String) -> Void = { _ in }) throws -> URL {
        try check()
        if source.isLibraryVideo { return try videoClip(source, version: version, root: root, progress: progress) }
        if let output = cachedClip(source, seconds: seconds, motion: motion, longEdge: longEdge, motionPattern: motionPattern, version: version, root: root, expansion: expansion) {
            progress("Ready from cache"); return output
        }
        let record = CachedClipRecord(sourceIdentity: expansion.cacheIdentity(source.cacheIdentity), version: version, seconds: seconds, motion: motion, longEdge: longEdge, motionPattern: motionPattern)
        let output = ClipCacheCatalog.cacheDirectory(root: root).appendingPathComponent(record.filename)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A failed/empty previous cache entry must not prevent its replacement.
        if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
        let scratch = root.appendingPathComponent("Work/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        // Only our temporary input and generated Gaussian buffers are removed.
        defer { try? FileManager.default.removeItem(at: scratch) }
        let original = try preparedInput ?? export(source, version: version, into: scratch, progress: progress)
        let input = try expandedInput(original, configuration: expansion, directory: scratch.appendingPathComponent("expansion"), tools: tools, progress: progress)
        let scene = scratch.appendingPathComponent("scene", isDirectory: true)
        progress("Creating the Photos 3D scene…")
        try run(tools.appendingPathComponent("GenerateScene"), [input.path, scene.path], log: scratch.appendingPathComponent("inference.log"))
        try attachExpansionMetadata(input: input, configuration: expansion, scene: scene)
        let rendered = scratch.appendingPathComponent("clip.mp4")
        // Preserve each photo's aspect ratio in its clip. The player can then
        // switch between fill and fit immediately without another inference.
        progress("Rendering camera movement…")
        try run(tools.appendingPathComponent("RenderSlideshow"), [rendered.path, String(seconds), String(motion), "source:\(longEdge)", scene.path], log: scratch.appendingPathComponent("render.log"), environment: ["SPATIAL_MOTION_PATTERN": String(motionPattern), "SPATIAL_FRAMING": "fit"])
        try check()
        try FileManager.default.moveItem(at: rendered, to: output)
        try? ClipCacheCatalog.record(record, root: root)
        progress("Ready")
        return output
    }
}
