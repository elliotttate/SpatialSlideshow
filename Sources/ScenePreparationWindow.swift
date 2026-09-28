import Foundation

/// Protect a small set of prepared-but-not-yet-loaded scenes from disk eviction.
/// One serial producer waits before inference and retains the completed result.
/// The renderer releases each entry after acquiring its own scene lease.
final class ScenePreparationWindow: @unchecked Sendable {
    private let condition = NSCondition()
    private let capacity: Int
    private var leases: [URL: SceneCache.Lease] = [:]
    private var generation = 0

    init(capacity: Int = 6) { self.capacity = max(1, capacity) }
    deinit { clear() }

    var count: Int {
        condition.lock(); defer { condition.unlock() }
        return leases.count
    }
    var isFull: Bool {
        condition.lock(); defer { condition.unlock() }
        return leases.count >= capacity
    }

    /// Worker-thread wait. The cancellation callback deliberately runs outside
    /// our lock and may query the playback model or this window's progress.
    /// Clearing the window cancels any wait already in progress.
    func waitForCapacity(check: () throws -> Void) throws {
        condition.lock(); let expectedGeneration = generation; condition.unlock()
        while true {
            try check()
            condition.lock()
            guard generation == expectedGeneration else {
                condition.unlock(); throw CancellationError()
            }
            if leases.count < capacity {
                condition.unlock()
                try check()
                return
            }
            _ = condition.wait(until: Date().addingTimeInterval(0.1))
            condition.unlock()
        }
    }

    /// Call only from the serial producer after waitForCapacity. A false result
    /// means this URL was already protected. A missing or evicted scene throws
    /// rather than advertising a prepared item that cannot later be loaded.
    @discardableResult
    func retain(url: URL, root: URL) throws -> Bool {
        let key = url.standardizedFileURL
        condition.lock()
        if leases[key] != nil { condition.unlock(); return false }
        guard leases.count < capacity else {
            condition.unlock()
            throw NSError(domain: "ScenePreparationWindow", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The live scene preparation window is full. Wait for playback before preparing another scene."])
        }
        let expectedGeneration = generation
        condition.unlock()

        // Never acquire the cache's file lock while holding the condition. The
        // renderer and producer may be loading or trimming at the same time.
        guard let lease = SceneCache.lease(url, root: root) else {
            throw NSError(domain: "ScenePreparationWindow", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "The prepared 3D scene is no longer available. Prepare this photo again."])
        }
        condition.lock()
        guard generation == expectedGeneration else {
            condition.unlock(); lease.release(); throw CancellationError()
        }
        if leases[key] != nil { condition.unlock(); lease.release(); return false }
        guard leases.count < capacity else {
            condition.unlock(); lease.release()
            throw NSError(domain: "ScenePreparationWindow", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The live scene preparation window is full."])
        }
        leases[key] = lease
        condition.unlock()
        return true
    }

    func release(url: URL) {
        condition.lock()
        let lease = leases.removeValue(forKey: url.standardizedFileURL)
        condition.broadcast()
        condition.unlock()
        lease?.release()
    }

    /// Release all protected entries and wake blocked producers. Calls made
    /// after clear may reuse the empty window; an earlier wait/retain is stale.
    func clear() {
        condition.lock()
        generation += 1
        let previous = leases
        leases.removeAll()
        condition.broadcast()
        condition.unlock()
        previous.values.forEach { $0.release() }
    }
}
