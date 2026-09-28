import Foundation

@main
struct SceneCacheTest {
    static func main() throws {
        let manager = FileManager.default
        let arguments = CommandLine.arguments
        if arguments.count > 1, arguments[1] == "--lookup" {
            let result = SceneCache.lookup(sourceIdentity: "persist", version: "current", root: URL(fileURLWithPath: arguments[2]))
            exit(result == nil ? 1 : 0)
        }
        if arguments.count > 1, arguments[1] == "--lease" {
            let root = URL(fileURLWithPath: arguments[2])
            guard let lease = SceneCache.lease(URL(fileURLWithPath: arguments[3]), root: root) else { exit(1) }
            try Data().write(to: root.appendingPathComponent("lease-ready"))
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline && !manager.fileExists(atPath: root.appendingPathComponent("release-lease").path) {
                Thread.sleep(forTimeInterval: 0.01)
            }
            lease.release()
            return
        }
        let root = manager.temporaryDirectory.appendingPathComponent("SpatialSceneCacheTest-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
        }
        func fixture(_ name: String = UUID().uuidString) throws -> URL {
            let directory = root.appendingPathComponent("fixtures/" + name, isDirectory: true)
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            var buffers: [String: Any] = [:]
            for (name, components) in ["alphas": 1, "positions": 3, "scales": 3, "rotations": 4, "colors": 3] {
                // The predictor emits packed one-component half-float rows;
                // vector components are contiguous across those rows.
                let width = 64, height = components * 2, stride = width * 2
                buffers[name] = ["width": width, "height": height, "bytesPerRow": stride, "pixelFormat": 1_278_226_536]
                try Data(repeating: 1, count: stride * height).write(to: directory.appendingPathComponent(name + ".bin"))
            }
            let manifest: [String: Any] = ["width": 1280, "height": 720, "buffers": buffers]
            try JSONSerialization.data(withJSONObject: manifest).write(to: directory.appendingPathComponent("scene.json"))
            return directory
        }
        let fixture = try fixture()
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        expect(SceneCache.validateScene(fixture), "Packed predictor scene fixture is valid")
        expect(SceneCache.lookup(sourceIdentity: "persist", version: "current", root: cacheRoot) == nil, "An empty cache misses")
        expect(!manager.fileExists(atPath: cacheRoot.path), "A miss does not create directories")
        let persisted = try SceneCache.store(fixture, sourceIdentity: "persist", version: "current", root: cacheRoot)
        expect(SceneCache.lookup(sourceIdentity: "persist", version: "current", root: cacheRoot) == persisted, "Completed scene can be reused")
        expect(SceneCache.url(sourceIdentity: "persist", version: "original", root: cacheRoot) != persisted, "Photo version invalidates inference")
        expect(SceneCache.url(sourceIdentity: "persist-new-revision", version: "current", root: cacheRoot) != persisted, "A changed source invalidates inference")
        let restart = Process()
        restart.executableURL = URL(fileURLWithPath: arguments[0])
        restart.arguments = ["--lookup", cacheRoot.path]
        try restart.run(); restart.waitUntilExit()
        expect(restart.terminationStatus == 0, "Scene cache survives process restarts")

        let source = root.appendingPathComponent("source.jpg")
        try Data("synthetic photo identity".utf8).write(to: source)
        let photo = PhotoSource.file(source)
        let session = RenderSession()
        let plain = try SceneCache.store(fixture, sourceIdentity: photo.cacheIdentity, version: "current", root: cacheRoot)
        expect(session.cachedScene(photo, version: .current, root: cacheRoot) == plain, "RenderSession uses the persistent scene cache")
        let tools = root.appendingPathComponent("missing-tools")
        expect(try session.scene(photo, version: .current, root: cacheRoot, tools: tools) == plain, "Cached scenes need neither export nor inference tools")
        var expansion = PhotoExpansionConfiguration(percent: 10, modelFingerprint: "synthetic-model")
        let expanded = try SceneCache.store(fixture, sourceIdentity: expansion.cacheIdentity(photo.cacheIdentity), version: "current", root: cacheRoot)
        expansion.zoomOutPercent = 15
        expect(session.cachedScene(photo, version: .current, root: cacheRoot, expansion: expansion) == expanded, "Zoom-out override reuses the same inference scene")
        expansion.backend = .drawThingsFlux
        expect(session.cachedScene(photo, version: .current, root: cacheRoot, expansion: expansion) == nil, "Expansion backends have different inference keys")
        expansion = PhotoExpansionConfiguration(percent: 20, modelFingerprint: "synthetic-model")
        expect(session.cachedScene(photo, version: .current, root: cacheRoot, expansion: expansion) == nil, "Expansion amount has a different inference key")
        expansion = PhotoExpansionConfiguration(percent: 10, modelFingerprint: "updated-model")
        expect(session.cachedScene(photo, version: .current, root: cacheRoot, expansion: expansion) == nil, "Changed expansion model invalidates inference")
        try Data("changed synthetic photo size".utf8).write(to: source)
        expect(session.cachedScene(photo, version: .current, root: cacheRoot) == nil, "Source edits invalidate a session cache lookup")

        // Exercise the entire session's generation, promotion and reuse path
        // with a deterministic producer; no Apple model or Photos access.
        let fakeTools = root.appendingPathComponent("tools", isDirectory: true)
        try manager.createDirectory(at: fakeTools, withIntermediateDirectories: true)
        let producer = fakeTools.appendingPathComponent("GenerateScene")
        func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = "#!/bin/sh\nset -eu\nmkdir -p \"$2\"\ncp -R \(shellQuote(fixture.path + "/.")) \"$2/\"\n"
        try Data(script.utf8).write(to: producer)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: producer.path)
        let generated = try session.scene(photo, version: .current, root: cacheRoot, tools: fakeTools)
        expect(SceneCache.validateScene(generated), "RenderSession promotes a complete generated scene")
        try Data("#!/bin/sh\nexit 99\n".utf8).write(to: producer)
        expect(try RenderSession().scene(photo, version: .current, root: cacheRoot, tools: fakeTools) == generated,
               "A new session uses its cached scene even if inference would fail")
        expect((try manager.contentsOfDirectory(atPath: cacheRoot.appendingPathComponent("Work").path)).isEmpty,
               "Completed inference removes its temporary input and buffers")
        let cancelled = RenderSession()
        cancelled.cancel()
        do {
            _ = try cancelled.scene(photo, version: .current, root: cacheRoot, tools: fakeTools)
            preconditionFailure("Cancelled session returned a scene")
        } catch is CancellationError { checks += 1 }

        try Data([1, 2]).write(to: persisted.appendingPathComponent("rotations.bin"))
        expect(SceneCache.lookup(sourceIdentity: "persist", version: "current", root: cacheRoot) == nil, "A truncated vector buffer is rejected")
        expect(SceneCache.lease(persisted, root: cacheRoot) == nil, "A corrupt entry cannot be leased")
        _ = try SceneCache.store(fixture, sourceIdentity: "persist", version: "current", root: cacheRoot)
        expect(SceneCache.validateScene(persisted), "A corrupt cache can be atomically replaced")
        let incomplete = SceneCache.url(sourceIdentity: "incomplete", version: "current", root: cacheRoot)
        try manager.copyItem(at: fixture, to: incomplete)
        expect(SceneCache.lookup(sourceIdentity: "incomplete", version: "current", root: cacheRoot) == nil, "A scene without the completion marker is never ready")
        let metadataFixture = root.appendingPathComponent("metadata-fixture")
        try manager.copyItem(at: fixture, to: metadataFixture)
        try Data("{\"percent_per_edge\":10,\"zoom_out_percent\":0}".utf8).write(to: metadataFixture.appendingPathComponent("expansion.json"))
        let withMetadata = try SceneCache.store(metadataFixture, sourceIdentity: "expansion-metadata", version: "current", root: cacheRoot)
        try manager.removeItem(at: withMetadata.appendingPathComponent("expansion.json"))
        expect(SceneCache.lookup(sourceIdentity: "expansion-metadata", version: "current", root: cacheRoot) == nil,
               "Missing expansion metadata invalidates the scene rather than silently changing framing")
        let invalid = root.appendingPathComponent("invalid")
        try manager.copyItem(at: fixture, to: invalid)
        try manager.removeItem(at: invalid.appendingPathComponent("alphas.bin"))
        try manager.createSymbolicLink(at: invalid.appendingPathComponent("alphas.bin"), withDestinationURL: fixture.appendingPathComponent("alphas.bin"))
        expect(!SceneCache.validateScene(invalid), "External buffer symlinks cannot enter the cache")
        do {
            _ = try SceneCache.store(invalid, sourceIdentity: "invalid", version: "current", root: cacheRoot)
            preconditionFailure("Invalid scene was stored")
        } catch { checks += 1 }
        var progressChecks = 0
        do {
            _ = try SceneCache.store(fixture, sourceIdentity: "cancelled", version: "current", root: cacheRoot) {
                progressChecks += 1
                if progressChecks == 5 { throw CancellationError() }
            }
            preconditionFailure("Cancellation should throw")
        } catch is CancellationError { checks += 1 }
        expect(SceneCache.lookup(sourceIdentity: "cancelled", version: "current", root: cacheRoot) == nil, "Cancellation never publishes a partial scene")
        expect(!(try manager.contentsOfDirectory(atPath: SceneCache.directory(root: cacheRoot).path)).contains { $0.hasPrefix(".pending-") }, "Cancelled staging directories are removed")

        let evictionRoot = root.appendingPathComponent("eviction")
        let older = try SceneCache.store(fixture, sourceIdentity: "old", version: "current", root: evictionRoot)
        let newer = try SceneCache.store(fixture, sourceIdentity: "new", version: "current", root: evictionRoot)
        try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: older.appendingPathComponent("cache-entry.json").path)
        try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2)], ofItemAtPath: newer.appendingPathComponent("cache-entry.json").path)
        let bytes = try manager.contentsOfDirectory(at: newer, includingPropertiesForKeys: [.fileSizeKey])
            .reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        try SceneCache.trim(root: evictionRoot, byteLimit: bytes + 16)
        expect(!manager.fileExists(atPath: older.path) && manager.fileExists(atPath: newer.path), "Trimming evicts least recently used completed scene first")
        guard let lease = SceneCache.lease(newer, root: evictionRoot) else { preconditionFailure("Expected lease") }
        try SceneCache.trim(root: evictionRoot, byteLimit: 0)
        expect(manager.fileExists(atPath: newer.path), "Active scenes are protected from in-process eviction")
        lease.release(); lease.release()
        let external = Process()
        external.executableURL = URL(fileURLWithPath: arguments[0])
        external.arguments = ["--lease", evictionRoot.path, newer.path]
        try external.run()
        defer { if external.isRunning { external.terminate() } }
        let deadline = Date().addingTimeInterval(5)
        while !manager.fileExists(atPath: evictionRoot.appendingPathComponent("lease-ready").path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        expect(manager.fileExists(atPath: evictionRoot.appendingPathComponent("lease-ready").path), "A second process can lease a scene")
        try SceneCache.trim(root: evictionRoot, byteLimit: 0)
        expect(manager.fileExists(atPath: newer.path), "An active scene in another process survives trimming")
        try Data().write(to: evictionRoot.appendingPathComponent("release-lease"))
        external.waitUntilExit()
        try SceneCache.trim(root: evictionRoot, byteLimit: 0)
        expect(!manager.fileExists(atPath: newer.path), "Released scenes become evictable")
        let unknown = SceneCache.directory(root: evictionRoot).appendingPathComponent("user-file.txt")
        try Data("leave me alone".utf8).write(to: unknown)
        let abandoned = SceneCache.directory(root: evictionRoot).appendingPathComponent(".pending-\(UUID().uuidString)")
        try manager.copyItem(at: fixture, to: abandoned)
        try SceneCache.trim(root: evictionRoot, byteLimit: 0)
        expect(manager.fileExists(atPath: unknown.path), "Trimming only removes owned scene directories")
        expect(!manager.fileExists(atPath: abandoned.path), "Abandoned staging copies from a crashed writer are reclaimed")
        print("PASS \(checks) scene cache checks, including restart persistence and cross-process leases")
    }
}
