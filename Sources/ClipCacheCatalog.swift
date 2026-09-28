import Foundation
import CryptoKit

/// Sidecars retain the source and settings, so another launch can find earlier
/// variants rendered through the same color-managed pipeline.
struct CachedClipRecord: Codable {
    let schema: Int
    let sourceIdentity: String
    let version: String
    let seconds: Double
    let motion: Double
    let longEdge: Int
    let motionPattern: Int
    let filename: String

    init(sourceIdentity: String, version: PhotoVersion, seconds: Double, motion: Double, longEdge: Int, motionPattern: Int) {
        schema = 1
        self.sourceIdentity = sourceIdentity; self.version = version.rawValue
        self.seconds = seconds; self.motion = motion; self.longEdge = longEdge; self.motionPattern = motionPattern
        filename = ClipCacheCatalog.filename(sourceIdentity: sourceIdentity, version: version.rawValue, seconds: seconds, motion: motion, longEdge: longEdge, motionPattern: motionPattern)
    }
    var sourceKey: String { version + "|" + sourceIdentity }
}

final class ClipCacheCatalog {
    static let cacheKeyPrefix = "color-managed-v5"
    static func cacheDirectory(root: URL) -> URL {
        // Pre-color-management movies stay on disk, outside this namespace.
        // Neither their settings nor their sidecars establish correct colors.
        root.appendingPathComponent("Clip Cache", isDirectory: true)
            .appendingPathComponent("Color Managed v1", isDirectory: true)
    }
    private static let hex = Array("0123456789abcdef".utf8)
    private let directory: URL
    private(set) var filenames: Set<String> = []
    private var records: [String: [CachedClipRecord]] = [:]
    private var indexedNames: Set<String> = []
    private var scannedSources: Set<String> = []
    private let inventory: String
    private var scansChanged = false
    private struct RecoveryIndex: Codable {
        let schema: Int
        let inventory: String
        let scannedSources: Set<String>
    }

    static func digest(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).withUnsafeBytes { bytes in
            var result = [UInt8](repeating: 0, count: 64)
            for index in 0..<32 {
                let byte = bytes[index]
                result[index * 2] = hex[Int(byte >> 4)]
                result[index * 2 + 1] = hex[Int(byte & 15)]
            }
            return String(decoding: result, as: UTF8.self)
        }
    }
    static func filename(sourceIdentity: String, version: String, seconds: Double, motion: Double, longEdge: Int, motionPattern: Int) -> String {
        // Preserve all <=2x clips; higher strengths now orbit instead of
        // retracing the old path, so those movies must be rendered again.
        let motionRevision = motion > 2 ? "|orbit-v1" : ""
        return digest("\(cacheKeyPrefix)|\(version)|\(motionPattern)|\(sourceIdentity)|\(seconds)|\(motion)|\(longEdge)\(motionRevision)") + ".mp4"
    }
    static func record(_ record: CachedClipRecord, root: URL) throws {
        let url = cacheDirectory(root: root).appendingPathComponent(record.filename).deletingPathExtension().appendingPathExtension("json")
        // Atomic replacement is safe when replay and the producer find the same
        // movie concurrently. A metadata failure never invalidates a good movie.
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
    }

    init(root: URL, check: () throws -> Void) throws {
        directory = Self.cacheDirectory(root: root)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        // Read only this pipeline's directory once; sidecar recovery below uses
        // only Set lookups and never examines the old v4 cache directory.
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? []
        var sidecars: [URL] = []
        for (index, file) in files.enumerated() {
            if index % 64 == 0 { try check() }
            if file.pathExtension == "mp4" {
                let values = try? file.resourceValues(forKeys: keys)
                if values?.isRegularFile == true, (values?.fileSize ?? 0) > 0 { filenames.insert(file.lastPathComponent) }
            } else if file.pathExtension == "json" { sidecars.append(file) }
        }
        inventory = Self.digest(filenames.sorted().joined(separator: "\n"))
        let decoder = JSONDecoder()
        for (index, file) in sidecars.enumerated() {
            if index % 64 == 0 { try check() }
            guard let data = try? Data(contentsOf: file),
                  let entry = try? decoder.decode(CachedClipRecord.self, from: data), entry.schema == 1,
                  filenames.contains(entry.filename),
                  file.deletingPathExtension().lastPathComponent + ".mp4" == entry.filename,
                  entry.filename == Self.filename(sourceIdentity: entry.sourceIdentity, version: entry.version, seconds: entry.seconds, motion: entry.motion, longEdge: entry.longEdge, motionPattern: entry.motionPattern) else { continue }
            records[entry.sourceKey, default: []].append(entry)
            indexedNames.insert(entry.filename)
        }
        let recoveryURL = directory.appendingPathComponent("Replay Recovery.json")
        if let data = try? Data(contentsOf: recoveryURL),
           let recovery = try? decoder.decode(RecoveryIndex.self, from: data),
           recovery.schema == 1, recovery.inventory == inventory { scannedSources = recovery.scannedSources }
    }

    func saveRecoveryIndex() {
        guard scansChanged else { return }
        let index = RecoveryIndex(schema: 1, inventory: inventory, scannedSources: scannedSources)
        if let data = try? JSONEncoder().encode(index) {
            try? data.write(to: directory.appendingPathComponent("Replay Recovery.json"), options: .atomic)
        }
    }

    private func remember(_ entry: CachedClipRecord, root: URL) -> URL {
        if indexedNames.insert(entry.filename).inserted {
            records[entry.sourceKey, default: []].append(entry)
            try? Self.record(entry, root: root)
        }
        return directory.appendingPathComponent(entry.filename)
    }

    func replay(sourceIdentity: String, seconds: Double, motion: Double, longEdge: Int, motionPattern: Int, version: PhotoVersion, root: URL, recoverUnindexed: Bool = true, check: () throws -> Void) throws -> URL? {
        try check()
        let exact = CachedClipRecord(sourceIdentity: sourceIdentity, version: version, seconds: seconds, motion: motion, longEdge: longEdge, motionPattern: motionPattern)
        if filenames.contains(exact.filename) { return remember(exact, root: root) }
        if let variants = records[exact.sourceKey], !variants.isEmpty {
            // Prefer settings closest to this play request, deterministically.
            let best = variants.min {
                func score(_ entry: CachedClipRecord) -> Double {
                    (entry.longEdge == longEdge ? 0 : 100) + abs(entry.seconds - seconds) * 10 + abs(entry.motion - motion) + (entry.motionPattern == motionPattern ? 0 : 0.1)
                }
                let first = score($0), second = score($1)
                return first == second ? $0.filename < $1.filename : first < second
            }!
            return directory.appendingPathComponent(best.filename)
        }
        guard recoverUnindexed, indexedNames.count < filenames.count, !scannedSources.contains(exact.sourceKey) else { return nil }

        func unique<T: Hashable>(_ values: [T]) -> [T] {
            var seen: Set<T> = []; return values.filter { seen.insert($0).inserted }
        }
        let durations = unique([seconds, 6, 3, 9, 12] + (3...12).map(Double.init))
        // Include literal picker values plus historical slider arithmetic. The
        // exact Double spelling matters because the key hashes String(Double).
        var strengths = [motion, 1, 0.5, 1.5, 1.8, 0.25, 0.75]
        strengths += (5...36).map { Double($0) / 20 }
        strengths += (0...31).map { 0.25 + Double($0) * 0.05 }
        strengths += (5...36).map { Double($0) * 0.05 }
        var accumulated = 0.25
        for _ in 0...31 { strengths.append(accumulated); accumulated += 0.05 }
        strengths = unique(strengths)
        let edges = unique([longEdge, 1920, 3840])
        let patterns = unique([motionPattern] + Array(0...5))
        var attempts = 0
        // Common values are first, and all movement patterns are considered.
        for duration in durations {
            for strength in strengths {
                for edge in edges {
                    for pattern in patterns {
                        if attempts % 128 == 0 { try check() }
                        attempts += 1
                        let entry = CachedClipRecord(sourceIdentity: sourceIdentity, version: version, seconds: duration, motion: strength, longEdge: edge, motionPattern: pattern)
                        if filenames.contains(entry.filename) { return remember(entry, root: root) }
                    }
                }
            }
        }
        scannedSources.insert(exact.sourceKey); scansChanged = true
        return nil
    }
}
