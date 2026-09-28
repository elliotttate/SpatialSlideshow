import Foundation
import CryptoKit
import Darwin

/// The inference result, independent of camera movement and display settings.
/// Completed entries survive launches. Leases protect scenes while a renderer
/// or its preload queue needs their files, including across app processes.
enum SceneCache {
    static let pipelineVersion = "gaussian-color-managed-v1"
    static let defaultByteLimit: Int64 = 4 * 1_024 * 1_024 * 1_024
    private static let lock = NSRecursiveLock()
    private static let markerName = "cache-entry.json"
    private static let bufferComponents = ["alphas": 1, "positions": 3, "scales": 3, "rotations": 4, "colors": 3]

    final class Lease {
        let url: URL
        private var descriptor: Int32
        private let lock = NSLock()
        fileprivate init(url: URL, descriptor: Int32) { self.url = url; self.descriptor = descriptor }
        func release() {
            lock.lock(); defer { lock.unlock() }
            guard descriptor >= 0 else { return }
            flock(descriptor, LOCK_UN); close(descriptor); descriptor = -1
        }
        deinit { release() }
    }

    static func directory(root: URL) -> URL {
        root.appendingPathComponent("Scene Cache", isDirectory: true)
            .appendingPathComponent(pipelineVersion, isDirectory: true)
    }

    static func url(sourceIdentity: String, version: String, root: URL) -> URL {
        // JSON avoids ambiguity when a source path itself contains separators.
        let key = try! JSONSerialization.data(withJSONObject: [pipelineVersion, version, sourceIdentity])
        let digest = SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
        return directory(root: root).appendingPathComponent(digest, isDirectory: true)
    }

    static func lookup(sourceIdentity: String, version: String, root: URL) -> URL? {
        let candidate = url(sourceIdentity: sourceIdentity, version: version, root: root)
        // Read-only misses do not create an empty cache.
        guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        return try? withCacheLock(root: root) {
            guard validEntry(candidate, root: root) else { throw failure("Incomplete cached 3D scene.") }
            touch(candidate)
            return candidate
        }
    }

    /// Retain the returned object until loading / playback no longer needs the
    /// directory. A nil result means the entry was evicted or damaged; regenerate.
    static func lease(_ sceneURL: URL, root: URL) -> Lease? {
        try? withCacheLock(root: root) {
            guard validEntry(sceneURL, root: root) else { throw failure("The cached 3D scene is no longer available.") }
            let fd = open(sceneURL.appendingPathComponent(".lease").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { throw failure("Could not protect the cached 3D scene.") }
            guard flock(fd, LOCK_SH | LOCK_NB) == 0 else { close(fd); throw failure("The cached 3D scene is being replaced.") }
            touch(sceneURL)
            return Lease(url: sceneURL, descriptor: fd)
        }
    }

    /// Only a fully validated staging directory is atomically promoted. The
    /// caller's scratch scene remains owned by its RenderSession.
    static func store(_ scene: URL, sourceIdentity: String, version: String, root: URL,
                      byteLimit: Int64 = defaultByteLimit, check: () throws -> Void = {}) throws -> URL {
        try check()
        guard validateScene(scene) else { throw failure("Photos produced an incomplete or invalid 3D scene. Try this photo again.") }
        let destination = url(sourceIdentity: sourceIdentity, version: version, root: root)
        let staging = directory(root: root).appendingPathComponent(".pending-\(UUID().uuidString)", isDirectory: true)
        let stagingLease = try withCacheLock(root: root) { () throws -> Lease in
            try removeAbandonedStaging(root: root)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            guard let lease = exclusiveLease(staging) else {
                try? FileManager.default.removeItem(at: staging)
                throw failure("Could not protect the new scene cache entry.")
            }
            return lease
        }
        defer { try? FileManager.default.removeItem(at: staging); stagingLease.release() }
        let files = ["scene.json", "expansion.json", "depths.bin"] + bufferComponents.keys.map { $0 + ".bin" }
        for file in files {
            try check()
            let input = scene.appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: input.path) {
                guard regularSize(input) != nil else { throw failure("Unexpected file in the generated 3D scene.") }
                try FileManager.default.copyItem(at: input, to: staging.appendingPathComponent(file))
            }
        }
        guard validateScene(staging) else { throw failure("Could not save the complete 3D scene cache.") }
        var sizes: [String: Int64] = [:]
        for file in files {
            if let size = regularSize(staging.appendingPathComponent(file)) { sizes[file] = size }
        }
        let marker: [String: Any] = ["schema": 1, "pipeline": pipelineVersion, "key": destination.lastPathComponent, "files": sizes]
        try JSONSerialization.data(withJSONObject: marker, options: [.sortedKeys])
            .write(to: staging.appendingPathComponent(markerName), options: .atomic)
        return try withCacheLock(root: root) {
            try check()
            if validEntry(destination, root: root) {
                touch(destination)
                try trimUnlocked(root: root, byteLimit: byteLimit, protecting: [destination])
                return destination
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                guard ownedLocation(destination, root: root), !isSymlink(destination),
                      let exclusive = exclusiveLease(destination) else {
                    throw failure("The incomplete cached scene is in use. Stop playback and try again.")
                }
                defer { exclusive.release() }
                try FileManager.default.removeItem(at: destination)
            }
            try check()
            try FileManager.default.moveItem(at: staging, to: destination)
            stagingLease.release()
            touch(destination)
            try trimUnlocked(root: root, byteLimit: byteLimit, protecting: [destination])
            return destination
        }
    }

    /// The limit may temporarily be exceeded by active leases or the newly
    /// generated scene. Release leases then trim to reclaim those entries.
    static func trim(root: URL, byteLimit: Int64 = defaultByteLimit, protecting: [URL] = []) throws {
        guard FileManager.default.fileExists(atPath: directory(root: root).path) else { return }
        try withCacheLock(root: root) { try trimUnlocked(root: root, byteLimit: byteLimit, protecting: protecting) }
    }

    /// Validate the producer's manifest and the exact packed half-float buffer
    /// sizes consumed by Apple's Gaussian renderer. Truncated and padded buffers
    /// cannot be advertised as ready.
    static func validateScene(_ scene: URL) -> Bool {
        guard !isSymlink(scene), let manifestSize = regularSize(scene.appendingPathComponent("scene.json")),
              manifestSize > 0, manifestSize <= 1_048_576,
              let data = try? Data(contentsOf: scene.appendingPathComponent("scene.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let width = positiveInteger(manifest["width"]), width <= 65_536,
              let height = positiveInteger(manifest["height"]), height <= 65_536,
              let buffers = manifest["buffers"] as? [String: [String: Any]],
              let alphaSize = regularSize(scene.appendingPathComponent("alphas.bin")),
              alphaSize > 0, alphaSize % 2 == 0, alphaSize <= 256 * 1_024 * 1_024 else { return false }
        for (name, components) in bufferComponents {
            guard let metadata = buffers[name],
                  let bufferWidth = positiveInteger(metadata["width"]),
                  let bufferHeight = positiveInteger(metadata["height"]),
                  let stride = positiveInteger(metadata["bytesPerRow"]),
                  positiveInteger(metadata["pixelFormat"]) == 1_278_226_536,
                  bufferWidth <= Int64.max / 2, stride == bufferWidth * 2,
                  bufferHeight <= Int64.max / stride,
                  let size = regularSize(scene.appendingPathComponent(name + ".bin")),
                  size == stride * bufferHeight, size == alphaSize * Int64(components) else { return false }
        }
        // Depth is not consumed by the live renderer, but do not preserve a
        // partial optional producer file in a supposedly completed entry.
        if let depth = buffers["depths"] {
            guard let stride = positiveInteger(depth["bytesPerRow"]),
                  let height = positiveInteger(depth["height"]), height <= Int64.max / stride,
                  regularSize(scene.appendingPathComponent("depths.bin")) == stride * height else { return false }
        }
        if FileManager.default.fileExists(atPath: scene.appendingPathComponent("expansion.json").path) {
            guard let size = regularSize(scene.appendingPathComponent("expansion.json")), size > 0, size <= 1_048_576,
                  let data = try? Data(contentsOf: scene.appendingPathComponent("expansion.json")),
                  (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { return false }
        }
        return true
    }

    private static func positiveInteger(_ value: Any?) -> Int64? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let number = value.doubleValue
        guard number.isFinite, number > 0, number < Double(Int64.max), number.rounded(.towardZero) == number else { return nil }
        return value.int64Value
    }

    private static func regularSize(_ url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize else { return nil }
        return Int64(size)
    }

    private static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private static func ownedLocation(_ url: URL, root: URL) -> Bool {
        let key = url.lastPathComponent
        return key.count == 64 && key.allSatisfy { ("0123456789abcdef").contains($0) }
            && url.standardizedFileURL.deletingLastPathComponent() == directory(root: root).standardizedFileURL
    }

    private static func validEntry(_ url: URL, root: URL) -> Bool {
        guard ownedLocation(url, root: root), validMarker(url), validateScene(url),
              let data = try? Data(contentsOf: url.appendingPathComponent(markerName)),
              let marker = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = marker["files"] as? [String: NSNumber] else { return false }
        let allowed = Set(["scene.json", "expansion.json", "depths.bin"] + bufferComponents.keys.map { $0 + ".bin" })
        let required = Set(["scene.json"] + bufferComponents.keys.map { $0 + ".bin" })
        guard required.isSubset(of: Set(files.keys)), Set(files.keys).isSubset(of: allowed) else { return false }
        // Optional expansion metadata is part of a completed scene too. Losing
        // it must not silently change the live camera's original-photo framing.
        return files.allSatisfy { name, size in
            positiveInteger(size) != nil && regularSize(url.appendingPathComponent(name)) == size.int64Value
        }
    }

    private static func validMarker(_ url: URL) -> Bool {
        guard let size = regularSize(url.appendingPathComponent(markerName)), size > 0, size <= 4096,
              let data = try? Data(contentsOf: url.appendingPathComponent(markerName)),
              let marker = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return marker["schema"] as? Int == 1 && marker["pipeline"] as? String == pipelineVersion
            && marker["key"] as? String == url.lastPathComponent
    }

    private static func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.appendingPathComponent(markerName).path)
    }

    private static func exclusiveLease(_ url: URL) -> Lease? {
        let descriptor = open(url.appendingPathComponent(".lease").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { close(descriptor); return nil }
        return Lease(url: url, descriptor: descriptor)
    }

    private static func trimUnlocked(root: URL, byteLimit: Int64, protecting: [URL]) throws {
        try removeAbandonedStaging(root: root)
        let manager = FileManager.default
        let protected = Set(protecting.map { $0.standardizedFileURL.path })
        let entries = try manager.contentsOfDirectory(at: directory(root: root), includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            .filter { ownedLocation($0, root: root) && !isSymlink($0) && validMarker($0) }
            .map { url -> (url: URL, bytes: Int64, accessed: Date) in
                let children = (try? manager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])) ?? []
                let size = children.reduce(Int64(0)) { $0 + (regularSize($1) ?? 0) }
                let accessed = (try? url.appendingPathComponent(markerName).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return (url, size, accessed)
            }.sorted { $0.accessed < $1.accessed }
        var total = entries.reduce(Int64(0)) { $0 + $1.bytes }
        for entry in entries where total > max(0, byteLimit) {
            guard !protected.contains(entry.url.standardizedFileURL.path), let lease = exclusiveLease(entry.url) else { continue }
            defer { lease.release() }
            try manager.removeItem(at: entry.url)
            total -= entry.bytes
        }
    }

    private static func removeAbandonedStaging(root: URL) throws {
        let manager = FileManager.default
        for url in try manager.contentsOfDirectory(at: directory(root: root), includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            let name = url.lastPathComponent
            guard name.hasPrefix(".pending-"), UUID(uuidString: String(name.dropFirst(9))) != nil,
                  !isSymlink(url), let lease = exclusiveLease(url) else { continue }
            defer { lease.release() }
            // Live writers hold an exclusive lease. After a crash, the kernel
            // releases it and the next store/trim reclaims the orphaned copy.
            try manager.removeItem(at: url)
        }
    }

    private static func withCacheLock<T>(root: URL, _ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        let parent = root.appendingPathComponent("Scene Cache", isDirectory: true)
        let directory = directory(root: root)
        guard !isSymlink(parent), !isSymlink(directory) else { throw failure("The scene cache directory is not a regular folder.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.appendingPathComponent(".cache-lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw failure("Could not open the scene cache lock.") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw failure("Could not lock the scene cache.") }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    private static func failure(_ description: String) -> NSError {
        NSError(domain: "SceneCache", code: 1, userInfo: [NSLocalizedDescriptionKey: description])
    }
}
