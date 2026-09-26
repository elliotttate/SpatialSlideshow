import Foundation

@main
enum PersistentReplayCacheTest {
    static func main() throws {
        let args = CommandLine.arguments
        let root = URL(fileURLWithPath: args[2])
        let session = RenderSession()
        let sources = ["a", "b", "c", "e"].map { PhotoSource.file(root.appendingPathComponent("\($0).jpg")) }
        if args.last == "restart" {
            let clips = try session.cachedReplayClips(sources, seconds: 12, motion: 0.25, longEdge: 1920, patterns: [1, 1, 1, 1], version: .current, root: root)
            let expanded = try session.cachedReplayClips(sources, seconds: 12, motion: 0.25, longEdge: 1920, patterns: [1, 1, 1, 1], version: .current, root: root, expansion: PhotoExpansionConfiguration(percent: 5, modelFingerprint: "test-model"))
            let report: [String: Any] = ["sourceIndexes": clips.map(\.1), "filenames": clips.map { $0.0.lastPathComponent }, "expandedIndexes": expanded.map(\.1)]
            try JSONSerialization.data(withJSONObject: report).write(to: root.appendingPathComponent("restart.json"))
            return
        }
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["a", "b", "c", "d", "e"] {
            try Data("photo \(name)".utf8).write(to: root.appendingPathComponent("\(name).jpg"))
        }
        let movie = URL(fileURLWithPath: args[1])
        var checks: [String] = []
        func expect(_ condition: Bool, _ description: String) {
            precondition(condition, description); checks.append(description)
        }
        func unindexed(_ source: PhotoSource, seconds: Double = 6, motion: Double = 1.5, edge: Int = 1920, pattern: Int = 5, version: PhotoVersion = .current, expansion: PhotoExpansionConfiguration = .disabled) throws -> URL {
            let url = session.clipCacheURL(source, seconds: seconds, motion: motion, longEdge: edge, motionPattern: pattern, version: version, root: root, expansion: expansion)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.copyItem(at: movie, to: url)
            return url
        }
        let oldDirectory = root.appendingPathComponent("Clip Cache", isDirectory: true)
        try manager.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
        let oldName = ClipCacheCatalog.digest("source-aspect-v4|current|2|\(sources[0].cacheIdentity)|9.0|1.8|3840") + ".mp4"
        let oldMovie = oldDirectory.appendingPathComponent(oldName)
        try manager.copyItem(at: movie, to: oldMovie)
        let oldSidecar: [String: Any] = ["schema": 1, "sourceIdentity": sources[0].cacheIdentity, "version": "current", "seconds": 9.0, "motion": 1.8, "longEdge": 3840, "motionPattern": 2, "filename": oldName]
        let oldMetadata = oldMovie.deletingPathExtension().appendingPathExtension("json")
        let oldMetadataBytes = try JSONSerialization.data(withJSONObject: oldSidecar)
        try oldMetadataBytes.write(to: oldMetadata)
        expect(session.cachedClip(sources[0], seconds: 9, motion: 1.8, longEdge: 3840, motionPattern: 2, version: .current, root: root) == nil, "Old v4 movie cannot satisfy exact lookup even with identical source and settings")
        let oldReplay = try session.cachedReplayClips([sources[0]], seconds: 9, motion: 1.8, longEdge: 3840, patterns: [2], version: .current, root: root)
        expect(oldReplay.isEmpty, "Old v4 movie and persistent sidecar cannot enter the corrected replay pool")
        let first = try unindexed(sources[0])
        let alternate = try unindexed(sources[0], seconds: 8, motion: 0.7, edge: 3840, pattern: 4)
        let original = try unindexed(sources[1], version: .original)
        _ = try unindexed(sources[2])
        try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1234)], ofItemAtPath: root.appendingPathComponent("c.jpg").path)
        _ = try unindexed(.file(root.appendingPathComponent("d.jpg")))
        let selected = [sources[0], sources[0], sources[1], sources[2]]
        let recovered = try session.cachedReplayClips(selected, seconds: 9, motion: 1.8, longEdge: 3840, patterns: [2, 2, 2, 2], version: .current, root: root)
        expect(recovered.count == 1 && recovered[0].1 == 0, "Color-managed variants deduplicate by source and exclude other sources, edits, and photo versions")
        expect([first, alternate].contains(recovered[0].0), "Waiting playback recovers a movie made with earlier render settings")
        expect(manager.fileExists(atPath: recovered[0].0.deletingPathExtension().appendingPathExtension("json").path), "Unindexed color-managed movie recovery saves persistent metadata")
        expect(session.cachedClip(sources[0], seconds: 9, motion: 1.8, longEdge: 3840, motionPattern: 2, version: .current, root: root) == nil, "Earlier replay variants do not satisfy exact producer settings")
        let exact = try unindexed(sources[0], seconds: 9, motion: 1.8, edge: 3840, pattern: 2)
        let preferred = try session.cachedReplayClips([sources[0]], seconds: 9, motion: 1.8, longEdge: 3840, patterns: [2], version: .current, root: root)
        expect(preferred.first?.0 == exact, "Exact requested render takes preference over earlier variants")
        var phases: [String] = []
        let producer = try session.clip(sources[0], seconds: 9, motion: 1.8, longEdge: 3840, motionPattern: 2, version: .current, root: root, tools: root.appendingPathComponent("missing-tools")) { phases.append($0) }
        expect(producer == exact && phases == ["Ready from cache"], "Exact producer cache hit needs no Photos model or renderer")
        let originals = try session.cachedReplayClips(sources, seconds: 9, motion: 1.8, longEdge: 3840, patterns: [2, 2, 2, 2], version: .original, root: root)
        expect(originals.count == 1 && originals[0].1 == 1 && originals[0].0 == original, "Original source request only replays the original source version")
        // These settings lie outside the sidecar recovery ranges: finding this on
        // a separate launch establishes that persisted metadata was loaded.
        let unusual = try unindexed(sources[3], seconds: 7.25, motion: 0.912345, edge: 2730, pattern: 3)
        expect(session.cachedClip(sources[3], seconds: 7.25, motion: 0.912345, longEdge: 2730, motionPattern: 3, version: .current, root: root) == unusual, "Exact hits index arbitrary render settings")
        let expand5 = PhotoExpansionConfiguration(percent: 5, modelFingerprint: "test-model")
        let expand10 = PhotoExpansionConfiguration(percent: 10, modelFingerprint: "test-model")
        let legacyExpandedIdentity = sources[2].cacheIdentity + "|apple-cleanup-motion-v1|5|test-model"
        let legacyExpanded = CachedClipRecord(sourceIdentity: legacyExpandedIdentity, version: .current, seconds: 6, motion: 1.5, longEdge: 1920, motionPattern: 5)
        let legacyExpandedURL = ClipCacheCatalog.cacheDirectory(root: root).appendingPathComponent(legacyExpanded.filename)
        try manager.copyItem(at: movie, to: legacyExpandedURL)
        try ClipCacheCatalog.record(legacyExpanded, root: root)
        let outdatedReplay = try session.cachedReplayClips([sources[2]], seconds: 6, motion: 1.5, longEdge: 1920, patterns: [5], version: .current, root: root, expansion: expand5)
        expect(outdatedReplay.isEmpty, "Old wide-view expanded clips never enter the original-composition replay pool")
        expect(manager.fileExists(atPath: legacyExpandedURL.path), "Framing invalidation preserves existing expanded files")
        let expandedMovie = try unindexed(sources[0], expansion: expand5)
        _ = session.cachedClip(sources[0], seconds: 6, motion: 1.5, longEdge: 1920, motionPattern: 5, version: .current, root: root, expansion: expand5)
        expect(expandedMovie != first, "Expansion clips have a separate cache identity from unexpanded clips")
        let expandedReplay = try session.cachedReplayClips(sources, seconds: 12, motion: 0.5, longEdge: 1920, patterns: [], version: .current, root: root, expansion: expand5)
        expect(expandedReplay.count == 1 && expandedReplay.first?.0 == expandedMovie, "Expanded replay uses only clips with the requested expansion amount")
        let wrongAmount = try session.cachedReplayClips(sources, seconds: 6, motion: 1.5, longEdge: 1920, patterns: [], version: .current, root: root, expansion: expand10)
        expect(wrongAmount.isEmpty, "Changing expansion amount cannot reuse plain or differently expanded clips")
        let wrongModel = try session.cachedReplayClips(sources, seconds: 6, motion: 1.5, longEdge: 1920, patterns: [], version: .current, root: root, expansion: PhotoExpansionConfiguration(percent: 5, modelFingerprint: "new-model"))
        expect(wrongModel.isEmpty, "Changing the model identity invalidates expanded clips")
        let expandedHit = try session.clip(sources[0], seconds: 6, motion: 1.5, longEdge: 1920, motionPattern: 5, version: .current, root: root, tools: root.appendingPathComponent("missing-tools"), expansion: expand5)
        expect(expandedHit == expandedMovie, "Expanded cache hits bypass expansion and Reframe entirely")
        let wide5 = PhotoExpansionConfiguration(percent: 5, modelFingerprint: "test-model", zoomOutPercent: 5)
        let wideMovie = try unindexed(sources[0], expansion: wide5)
        _ = session.cachedClip(sources[0], seconds: 6, motion: 1.5, longEdge: 1920, motionPattern: 5, version: .current, root: root, expansion: wide5)
        let wideReplay = try session.cachedReplayClips(sources, seconds: 9, motion: 1, longEdge: 1920, patterns: [], version: .current, root: root, expansion: wide5)
        expect(wideMovie != expandedMovie && wideReplay.count == 1 && wideReplay[0].0 == wideMovie, "Zoom-out allowance has an isolated persistent replay pool")
        let missingAllowance = try session.cachedReplayClips(sources, seconds: 9, motion: 1, longEdge: 1920, patterns: [], version: .current, root: root, expansion: PhotoExpansionConfiguration(percent: 5, modelFingerprint: "test-model", zoomOutPercent: 6))
        expect(missingAllowance.isEmpty, "A different zoom-out allowance cannot replay older framing")
        let zero5 = PhotoExpansionConfiguration(percent: 5, modelFingerprint: "test-model", zoomOutPercent: 0)
        expect(zero5.cacheIdentity("photo") == expand5.cacheIdentity("photo"), "Default zero allowance preserves current cache identities")
        expect(PhotoExpansionConfiguration(percent: 5, modelFingerprint: "test-model", zoomOutPercent: 99).allowedZoomOutPercent == 10, "Requested allowance is capped by actual generated area")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: args[0])
        child.arguments = [args[1], args[2], args[3], "restart"]
        try child.run(); child.waitUntilExit()
        expect(child.terminationStatus == 0, "Separate process cache lookup succeeds")
        let restart = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("restart.json"))) as! [String: Any]
        expect(restart["expandedIndexes"] as? [Int] == [0], "Expanded metadata survives another process with the matching amount")
        expect(restart["sourceIndexes"] as? [Int] == [0, 3], "A new process restores both prior source records without stale or wrong-version photos")
        expect((restart["filenames"] as? [String])?.contains(unusual.lastPathComponent) == true, "Persistent metadata survives launch and recovers settings beyond recovery enumeration")
        expect(!manager.fileExists(atPath: root.appendingPathComponent("Work").path), "Replay discovery creates no model or rendering scratch work")
        let cancelled = RenderSession(); cancelled.cancel()
        do {
            _ = try cancelled.cachedReplayClips(sources, seconds: 6, motion: 1, longEdge: 1920, patterns: [], version: .current, root: root)
            expect(false, "Cancelled lookup must throw")
        } catch is CancellationError { expect(true, "Cancelled lookup exits immediately") }
        expect([first, alternate, original, exact, unusual].allSatisfy { manager.fileExists(atPath: $0.path) }, "Discovery preserves all cached movies")
        let retainedMovie = try Data(contentsOf: oldMovie)
        let retainedMetadata = try Data(contentsOf: oldMetadata)
        let fixtureMovie = try Data(contentsOf: movie)
        expect(retainedMovie == fixtureMovie && retainedMetadata == oldMetadataBytes, "Old v4 movie and metadata remain on disk byte-for-byte unchanged")
        let report: [String: Any] = ["passed": true, "checks": checks, "restart": restart]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: args[3]))
        print("PASS \(checks.count) persistent replay cache checks")
    }
}
