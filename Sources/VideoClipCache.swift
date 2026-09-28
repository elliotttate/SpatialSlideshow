import Foundation
import AVFoundation
import Photos
import CryptoKit

/// The movie is kept at its own duration and resolution. Slideshow motion and
/// still-photo timing do not affect this cache, including across app launches.
enum VideoClipCache {
    static func directory(root: URL) -> URL {
        root.appendingPathComponent("Video Cache/Original Timing v1", isDirectory: true)
    }

    static func url(sourceIdentity: String, version: PhotoVersion, root: URL) -> URL {
        let key = "album-video-v1|\(version.rawValue)|\(sourceIdentity)"
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory(root: root).appendingPathComponent(name + ".mov")
    }

    static func existing(_ url: URL) -> URL? {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        return values?.isRegularFile == true && (values?.fileSize ?? 0) > 0 ? url : nil
    }
}

struct PreparedVideoAsset {
    let asset: AVAsset
    var videoComposition: AVVideoComposition? = nil
    var audioMix: AVAudioMix? = nil
}

private final class VideoOperationResult<Value>: @unchecked Sendable {
    let condition = NSCondition()
    var result: Result<Value, Error>?
    func finish(_ value: Result<Value, Error>) {
        condition.lock(); defer { condition.unlock() }
        result = value; condition.broadcast()
    }
}

extension RenderSession {
    func cachedVideoClip(_ source: PhotoSource, version: PhotoVersion, root: URL) -> URL? {
        VideoClipCache.existing(VideoClipCache.url(sourceIdentity: source.cacheIdentity, version: version, root: root))
    }

    func videoClip(_ source: PhotoSource, version: PhotoVersion, root: URL, progress: @escaping (String) -> Void = { _ in }) throws -> URL {
        try check()
        if let cached = cachedVideoClip(source, version: version, root: root) {
            progress("Video ready from cache")
            return cached
        }
        switch source {
        case .library(let asset):
            return try cacheLibraryVideo(asset, sourceIdentity: source.cacheIdentity, version: version, root: root, progress: progress)
        case .file(let url):
            return try cacheVideoAsset(PreparedVideoAsset(asset: AVURLAsset(url: url)), sourceIdentity: source.cacheIdentity, version: version, root: root, progress: progress)
        }
    }

    private func requestVideoExporter(_ asset: PHAsset, version: PhotoVersion, preset: String, progress: @escaping (String) -> Void) throws -> AVAssetExportSession {
        try check()
        guard asset.mediaType == .video else {
            throw videoError("The selected item is not a video.")
        }
        let state = VideoOperationResult<AVAssetExportSession>()
        let options = PHVideoRequestOptions()
        options.version = version == .original ? .original : .current
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.progressHandler = { value, _, stop, _ in
            if self.isCancelled { stop.pointee = true; return }
            progress("Downloading full-quality video from iCloud · \(min(100, max(0, Int(value * 100))))%")
        }
        progress("Loading full-quality video from Photos…")
        let manager = PHImageManager.default()
        // PHImageManager documents player-item requests as playback-only.
        // Ask Photos to construct an export session with its authorized source
        // and edits instead of exporting the player's transient streaming asset.
        let request = manager.requestExportSession(forVideo: asset, options: options, exportPreset: preset) { exporter, info in
            if let exporter {
                state.finish(.success(exporter))
            } else {
                let error = info?[PHImageErrorKey] as? Error
                state.finish(.failure(error ?? self.videoError("This video could not be loaded from Photos.")))
            }
        }
        do { return try waitForVideoResult(state, timeout: 300, stage: "Waiting for Photos / iCloud to deliver the video", progress: progress) }
        catch { manager.cancelImageRequest(request); throw error }
    }

    private func cacheLibraryVideo(_ asset: PHAsset, sourceIdentity: String, version: PhotoVersion, root: URL, progress: @escaping (String) -> Void) throws -> URL {
        let output = VideoClipCache.url(sourceIdentity: sourceIdentity, version: version, root: root)
        let directory = VideoClipCache.directory(root: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scratch = directory.appendingPathComponent(".work-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: scratch) }
        var failures: [String] = []
        for (index, preset) in [AVAssetExportPresetPassthrough, AVAssetExportPresetHEVCHighestQuality, AVAssetExportPresetHighestQuality].enumerated() {
            try check()
            do {
                let exporter = try requestVideoExporter(asset, version: version, preset: preset, progress: progress)
                // Render edits instead of silently dropping them in passthrough.
                if preset == AVAssetExportPresetPassthrough && (exporter.videoComposition != nil || exporter.audioMix != nil) { continue }
                guard exporter.supportedFileTypes.contains(.mov) else { continue }
                let temporary = scratch.appendingPathComponent("video-\(index).mov")
                progress(preset == AVAssetExportPresetPassthrough ? "Caching full-quality video…" : "Preparing edited video…")
                try waitForVideoOperation(timeout: 7200, stage: "Preparing full-quality video", progress: { phase in
                    progress("\(phase) · \(Int(exporter.progress * 100))%")
                }) { try await exporter.export(to: temporary, as: .mov) }
                try check()
                let movie = AVURLAsset(url: temporary)
                let valid = try waitForVideoOperation {
                    let duration = try await movie.load(.duration)
                    let tracks = try await movie.loadTracks(withMediaType: .video)
                    return duration.isNumeric && duration.seconds > 0 && !tracks.isEmpty
                }
                guard valid, VideoClipCache.existing(temporary) != nil else { throw videoError("The exported video is incomplete.") }
                try check()
                if let cached = VideoClipCache.existing(output) { return cached }
                if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
                try FileManager.default.moveItem(at: temporary, to: output)
                progress("Video ready")
                return output
            } catch {
                try check()
                let value = error as NSError
                if error is CancellationError || StorageRecovery.isOutOfSpace(error) || StorageRecovery.isOffline(error)
                    || (value.domain == "SpatialSlideshow.Video" && value.code == 2)
                    || (value.domain == NSURLErrorDomain && value.code == NSURLErrorTimedOut) { throw error }
                var detail: [String] = []
                var current: NSError? = error as NSError
                for _ in 0..<4 {
                    guard let value = current else { break }
                    detail.append("\(value.domain) \(value.code): \(value.localizedDescription)")
                    current = value.userInfo[NSUnderlyingErrorKey] as? NSError
                }
                failures.append(detail.joined(separator: " / "))
            }
        }
        throw videoError("Photos could not export this video. " + failures.joined(separator: "; "))
    }

    /// Shared with the focused cache test so real local AV assets exercise the
    /// same export, validation, cancellation and atomic publication as Photos.
    func cacheVideoAsset(_ video: PreparedVideoAsset, sourceIdentity: String, version: PhotoVersion, root: URL, progress: @escaping (String) -> Void = { _ in }) throws -> URL {
        try check()
        let output = VideoClipCache.url(sourceIdentity: sourceIdentity, version: version, root: root)
        if let cached = VideoClipCache.existing(output) { return cached }
        let directory = VideoClipCache.directory(root: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scratch = directory.appendingPathComponent(".work-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let hasVideo = try waitForVideoOperation { try await !video.asset.loadTracks(withMediaType: .video).isEmpty }
        guard hasVideo else { throw videoError("This movie has no playable video track.") }
        // Composition/audio processing cannot be represented by passthrough.
        // HEVC retains wide-gamut/HDR video when a render is needed.
        let presets = video.videoComposition == nil && video.audioMix == nil
            ? [AVAssetExportPresetPassthrough, AVAssetExportPresetHEVCHighestQuality, AVAssetExportPresetHighestQuality]
            : [AVAssetExportPresetHEVCHighestQuality, AVAssetExportPresetHighestQuality]
        var lastError: Error?
        for (index, preset) in presets.enumerated() {
            try check()
            guard let exporter = AVAssetExportSession(asset: video.asset, presetName: preset), exporter.supportedFileTypes.contains(.mov) else { continue }
            exporter.videoComposition = video.videoComposition
            exporter.audioMix = video.audioMix
            exporter.shouldOptimizeForNetworkUse = false
            let temporary = scratch.appendingPathComponent("video-\(index).mov")
            progress(preset == AVAssetExportPresetPassthrough ? "Caching full-quality video…" : "Preparing edited video…")
            do {
                try waitForVideoOperation(timeout: 7200, stage: "Preparing full-quality video", progress: progress) {
                    try await exporter.export(to: temporary, as: .mov)
                }
                try check()
                let movie = AVURLAsset(url: temporary)
                let valid = try waitForVideoOperation {
                    let duration = try await movie.load(.duration)
                    let tracks = try await movie.loadTracks(withMediaType: .video)
                    return duration.isNumeric && duration.seconds > 0 && !tracks.isEmpty
                }
                guard valid, VideoClipCache.existing(temporary) != nil else { throw videoError("The exported video is incomplete.") }
                try check()
                // Both paths are on the same filesystem. Only a complete movie
                // becomes visible at the stable cache URL in one rename.
                if let cached = VideoClipCache.existing(output) { return cached }
                if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
                try FileManager.default.moveItem(at: temporary, to: output)
                progress("Video ready")
                return output
            } catch {
                try check()
                if error is CancellationError { throw error }
                lastError = error
            }
        }
        throw lastError ?? videoError("This video could not be exported for playback.")
    }

    private func waitForVideoOperation<Value>(timeout: TimeInterval = 300, stage: String = "Preparing video", progress: (String) -> Void = { _ in }, _ operation: @escaping () async throws -> Value) throws -> Value {
        let state = VideoOperationResult<Value>()
        let task = Task.detached {
            do { state.finish(.success(try await operation())) }
            catch { state.finish(.failure(error)) }
        }
        do { return try waitForVideoResult(state, timeout: timeout, stage: stage, progress: progress) }
        catch {
            // The async export API cancels when its Task is cancelled. Give it
            // a short bounded opportunity to close its output before cleanup.
            task.cancel()
            let deadline = Date().addingTimeInterval(1)
            state.condition.lock()
            while state.result == nil && Date() < deadline { _ = state.condition.wait(until: deadline) }
            state.condition.unlock()
            throw error
        }
    }

    private func waitForVideoResult<Value>(_ state: VideoOperationResult<Value>, timeout: TimeInterval, stage: String, progress: (String) -> Void) throws -> Value {
        let started = Date()
        let deadline = started.addingTimeInterval(timeout)
        var lastUpdate = started
        state.condition.lock()
        while state.result == nil && !isCancelled && Date() < deadline {
            _ = state.condition.wait(until: Date().addingTimeInterval(0.1))
            if state.result == nil && Date().timeIntervalSince(lastUpdate) >= 5 {
                lastUpdate = Date()
                let elapsed = Int(lastUpdate.timeIntervalSince(started))
                state.condition.unlock()
                progress("\(stage) · \(elapsed)s elapsed" + (elapsed >= 30 ? " · Taking longer than usual" : ""))
                state.condition.lock()
            }
        }
        let result = state.result
        state.condition.unlock()
        try check()
        guard let result else { throw videoError("\(stage) timed out after \(Int(timeout)) seconds. Try opening this video in Photos, then retry the album.", code: 2) }
        return try result.get()
    }

    private func videoError(_ message: String, code: Int = 1) -> NSError {
        NSError(domain: "SpatialSlideshow.Video", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
