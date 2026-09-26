import Foundation

/// Downloads a small window ahead without running multiple model processes.
/// Ordinarily yields album order. A slow head item remains in flight while
/// later ready items may pass it after the grace period.
final class AlbumPreparationQueue<Value>: @unchecked Sendable {
    private let condition = NSCondition()
    private let workers = OperationQueue()
    private let count: Int
    private let capacity: Int
    private let grace: TimeInterval
    private let check: () throws -> Void
    private let prepare: (Int) throws -> Value
    private var submitted = 0
    private var outstanding: [Int: TimeInterval] = [:]
    private var results: [Int: Result<Value, Error>] = [:]
    private var stopped = false

    init(count: Int, concurrentLoads: Int = 3, capacity: Int = 6,
         orderGrace: TimeInterval = 8,
         check: @escaping () throws -> Void,
         prepare: @escaping (Int) throws -> Value) {
        self.count = count; self.capacity = max(1, capacity)
        self.grace = orderGrace; self.check = check; self.prepare = prepare
        workers.maxConcurrentOperationCount = max(1, concurrentLoads)
        workers.qualityOfService = .userInitiated
    }

    private func fill() {
        condition.lock(); defer { condition.unlock() }
        while !stopped && submitted < count && outstanding.count < capacity {
            let index = submitted; submitted += 1
            outstanding[index] = ProcessInfo.processInfo.systemUptime
            workers.addOperation { [self] in
                let result = Result { try check(); return try prepare(index) }
                condition.lock()
                if !stopped { results[index] = result }
                condition.broadcast(); condition.unlock()
            }
        }
    }

    /// Call from the serial rendering worker. Errors belong to their item,
    /// allowing other assets to continue. A cancelled session stops the queue.
    func next() throws -> (Int, Result<Value, Error>)? {
        fill()
        while true {
            try check()
            condition.lock()
            if stopped { condition.unlock(); throw CancellationError() }
            guard let head = outstanding.keys.min() else { condition.unlock(); return nil }
            let elapsed = ProcessInfo.processInfo.systemUptime - outstanding[head]!
            let ready = results[head] != nil ? head : (elapsed >= grace ? results.keys.min() : nil)
            if let index = ready, let result = results.removeValue(forKey: index) {
                outstanding.removeValue(forKey: index)
                condition.unlock()
                return (index, result)
            }
            _ = condition.wait(until: Date().addingTimeInterval(0.1))
            condition.unlock()
        }
    }

    /// In-flight loaders observe the shared session cancellation flag. Clear
    /// buffered owners now; late results are discarded and clean themselves up.
    func stop() {
        condition.lock(); stopped = true; results.removeAll(); condition.broadcast(); condition.unlock()
        workers.cancelAllOperations()
    }
}

/// Keeps downloaded originals alive only until their single render completes.
final class PreparedAlbumItem {
    enum Content { case movie(URL), photo(URL) }
    let content: Content
    private let scratch: URL?
    init(_ content: Content, scratch: URL? = nil) { self.content = content; self.scratch = scratch }
    deinit { if let scratch { try? FileManager.default.removeItem(at: scratch) } }
}
