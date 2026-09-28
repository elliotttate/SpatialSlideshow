import Foundation
import CryptoKit

@main
struct ClipCacheTest {
    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("SpatialClipCacheTest-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source.jpg")
        try Data("source photo".utf8).write(to: sourceURL)
        let source = PhotoSource.file(sourceURL)
        let session = RenderSession()
        var checks: [String] = []
        func check(_ value: Bool, _ description: String) {
            precondition(value, description)
            checks.append(description)
        }
        let identities = (0..<300).map { "stable-photo-\($0)" }
        let patterns = identities.enumerated().map { MotionStyle.varied.pattern(for: $0.offset, sourceIdentity: $0.element) }
        let reordered = identities.reversed().enumerated().map { MotionStyle.varied.pattern(for: $0.offset, sourceIdentity: $0.element) }
        check(patterns == Array(reordered.reversed()), "Varied movement stays attached to each photo after shuffle")
        check(Set(patterns).count == 6, "A 300-photo album uses all six camera patterns")
        for style in MotionStyle.allCases where style != .varied {
            check(identities.enumerated().allSatisfy { style.pattern(for: $0.offset, sourceIdentity: $0.element) == style.rawValue }, "Fixed style \(style.title) remains fixed")
        }
        func url(seconds: Double = 6, motion: Double = 1, longEdge: Int = 1920, pattern: Int = 2, version: PhotoVersion = .current) -> URL {
            session.clipCacheURL(source, seconds: seconds, motion: motion, longEdge: longEdge, motionPattern: pattern, version: version, root: root)
        }
        func cached() -> URL? {
            session.cachedClip(source, seconds: 6, motion: 1, longEdge: 1920, motionPattern: 2, version: .current, root: root)
        }
        let output = url()
        let managedKey = "color-managed-v5|current|2|\(source.cacheIdentity)|6.0|1.0|1920"
        let managedName = SHA256.hash(data: Data(managedKey.utf8)).map { String(format: "%02x", $0) }.joined() + ".mp4"
        check(output.lastPathComponent == managedName, "Cache filenames use the color-managed-v5 render key")
        let appleExpansion = PhotoExpansionConfiguration(percent: 5, modelFingerprint: "model")
        var kleinExpansion = appleExpansion; kleinExpansion.backend = .fluxKlein
        check(appleExpansion.cacheIdentity("photo") == "photo|apple-cleanup-motion-v2|5|model", "Adding FLUX preserves existing Apple expansion cache identities")
        check(kleinExpansion.cacheIdentity("photo") != appleExpansion.cacheIdentity("photo"), "Outpainting providers cannot reuse each other's rendered clips")
        var drawThingsExpansion = appleExpansion; drawThingsExpansion.backend = .drawThingsFlux
        check(Set([appleExpansion, kleinExpansion, drawThingsExpansion].map { $0.cacheIdentity("photo") }).count == 3,
              "Draw Things, MLX and Apple expansions have separate persistent clip caches")
        check(kleinExpansion.cacheIdentity("photo") == "photo|flux-klein-motion-v1|5|model",
              "Adding Draw Things preserves prior MLX expansion cache identities")
        var zoomedExpansion = kleinExpansion; zoomedExpansion.zoomOutPercent = 10
        check(zoomedExpansion.cacheIdentity("photo") != kleinExpansion.cacheIdentity("photo"), "FLUX clips respect the zoom-out override")
        check(PhotoExpansionConfiguration.disabled.cacheIdentity("photo") == "photo", "Disabled expansion preserves original-photo caches")
        check(output.deletingLastPathComponent() == root.appendingPathComponent("Clip Cache/Color Managed v1", isDirectory: true), "Corrected renders use the versioned color-managed cache directory")
        let firstPattern = MotionStyle.varied.pattern(for: 0, sourceIdentity: source.cacheIdentity)
        let shuffledPattern = MotionStyle.varied.pattern(for: 299, sourceIdentity: source.cacheIdentity)
        check(url(pattern: firstPattern) == url(pattern: shuffledPattern), "Shuffling an album resolves the same photo to the same cached clip path")
        check(cached() == nil && !manager.fileExists(atPath: output.deletingLastPathComponent().path), "Cache lookup does not create files or directories")
        check(Set([output, url(seconds: 9), url(motion: 1.5), url(longEdge: 3840), url(pattern: 3), url(version: .original)]).count == 6, "Duration, strength, resolution, movement and photo version each invalidate the cache")
        check(Set([url(motion: 1.8), url(motion: 2), url(motion: 2.05), url(motion: 3), url(motion: 4)]).count == 5,
              "Higher strengths render distinct clips without replacing existing motion caches")
        try manager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: output)
        check(cached() == nil, "Empty cache files are rejected")
        try manager.removeItem(at: output)
        try manager.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[1]), to: output)
        check(cached() == output, "A completed cached clip is reusable")
        var progress: [String] = []
        let oldHighMotionKey = "color-managed-v5|current|2|\(source.cacheIdentity)|6.0|4.0|1920"
        let oldHighMotionName = ClipCacheCatalog.digest(oldHighMotionKey) + ".mp4"
        check(url(motion: 4).lastPathComponent != oldHighMotionName,
              "High-strength orbit clips do not reuse the old reversing-motion cache")
        let hit = try session.clip(source, seconds: 6, motion: 1, longEdge: 1920, motionPattern: 2, version: .current, root: root, tools: root.appendingPathComponent("nonexistent-model-and-renderer"), progress: { progress.append($0) })
        check(hit == output && progress == ["Ready from cache"], "Cache hit returns without model inference or rendering")
        check(!manager.fileExists(atPath: root.appendingPathComponent("Work").path), "Cache hit does not create scratch work or export an image")
        try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1234)], ofItemAtPath: sourceURL.path)
        check(url() != output && cached() == nil, "Source modification invalidates the cache")
        let changedTimeURL = url()
        try Data("different source photo length".utf8).write(to: sourceURL)
        try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1234)], ofItemAtPath: sourceURL.path)
        check(url() != changedTimeURL, "Source file size changes invalidate even with preserved modification time")
        let result: [String: Any] = ["passed": true, "checks": checks, "patterns": patterns, "scope": "Uses production cache code and production movement enum declarations; cached hit uses a real MP4 with missing model/render executables."]
        let evidence = URL(fileURLWithPath: CommandLine.arguments[2])
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: evidence, options: .atomic)
        print("PASS \(checks.count) cache checks")
    }
}
