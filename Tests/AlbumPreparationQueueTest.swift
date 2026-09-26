import Foundation

final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var maximum = 0
    private var started: [Int] = []
    private var cancelled = false
    func begin(_ index: Int) { lock.lock(); active += 1; maximum = max(maximum, active); started.append(index); lock.unlock() }
    func end() { lock.lock(); active -= 1; lock.unlock() }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws { lock.lock(); let value = cancelled; lock.unlock(); if value { throw CancellationError() } }
    var snapshot: (Int, Int, [Int]) { lock.lock(); defer { lock.unlock() }; return (active, maximum, started) }
}

@main struct AlbumPreparationQueueTest {
    static func main() throws {
        var checks: [String] = []
        func check(_ condition: Bool, _ message: String) { precondition(condition, message); checks.append(message) }
        func waitUntil(_ predicate: () -> Bool) {
            let end = Date().addingTimeInterval(3)
            while !predicate() && Date() < end { Thread.sleep(forTimeInterval: 0.01) }
            precondition(predicate(), "Timed out waiting for test worker")
        }

        // Reproduce the actual failure: photo 1 never reports progress while
        // later requests finish. Its original request must remain alive.
        let gate = DispatchSemaphore(value: 0)
        let slow = AlbumPreparationQueue<Int>(count: 4, orderGrace: 0.08, check: {}) { index in
            if index == 0 { gate.wait() }
            return index
        }
        let start = Date()
        let first = try slow.next()!
        check(try first.0 == 1 && first.1.get() == 1, "A stalled first download yields the next ready photo")
        check(Date().timeIntervalSince(start) < 1, "Startup does not wait for the stalled request timeout")
        gate.signal()
        var visited = [first.0]
        while let (index, result) = try slow.next() { check(try result.get() == index, "Ready item keeps its album identity"); visited.append(index) }
        check(visited.count == 4 && Set(visited) == Set(0..<4), "Delayed photo returns and all items appear exactly once")
        slow.stop()

        let probe = Probe()
        let bounded = AlbumPreparationQueue<Int>(count: 30, orderGrace: 1, check: {}) { index in
            probe.begin(index); defer { probe.end() }
            Thread.sleep(forTimeInterval: 0.04)
            return index
        }
        var order: [Int] = []
        order.append(try bounded.next()!.1.get())
        Thread.sleep(forTimeInterval: 0.2) // Simulate a paused/slow consumer.
        check(probe.snapshot.2.count == 6, "Prefetch stores at most six items while the consumer waits")
        check(probe.snapshot.1 == 3, "Three independent downloads run concurrently and never exceed the limit")
        while let (_, result) = try bounded.next() { order.append(try result.get()) }
        check(order == Array(0..<30), "Normally available items preserve album order through repeated refills")
        bounded.stop()

        enum Failure: Error { case missing }
        let failures = AlbumPreparationQueue<Int>(count: 5, check: {}) { index in
            if index == 2 { throw Failure.missing }
            return index
        }
        var good: [Int] = [], failed: [Int] = []
        while let (index, result) = try failures.next() {
            switch result { case .success(let value): good.append(value); case .failure: failed.append(index) }
        }
        check(good == [0, 1, 3, 4] && failed == [2], "One unavailable item does not discard subsequent downloads")
        failures.stop()

        let cancellation = Probe()
        let started = DispatchSemaphore(value: 0), cancelledNext = DispatchSemaphore(value: 0)
        let cancellable = AlbumPreparationQueue<Int>(count: 100, check: cancellation.check) { index in
            cancellation.begin(index); defer { cancellation.end() }; started.signal()
            while true { try cancellation.check(); Thread.sleep(forTimeInterval: 0.01) }
        }
        DispatchQueue.global().async {
            do { _ = try cancellable.next(); preconditionFailure("Expected cancellation") }
            catch is CancellationError { cancelledNext.signal() }
            catch { preconditionFailure("Unexpected error: \(error)") }
        }
        for _ in 0..<3 { precondition(started.wait(timeout: .now() + 2) == .success) }
        cancellation.cancel()
        check(cancelledNext.wait(timeout: .now() + 1) == .success, "Stop interrupts waiting for a ready item promptly")
        cancellable.stop()
        waitUntil { cancellation.snapshot.0 == 0 }
        check(cancellation.snapshot.2.count == 3, "Cancellation prevents queued requests from downloading more assets")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ownedProbe = Probe()
        let owned = AlbumPreparationQueue<PreparedAlbumItem>(count: 6, check: {}) { index in
            ownedProbe.begin(index); defer { ownedProbe.end() }
            let scratch = root.appendingPathComponent(String(index))
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let input = scratch.appendingPathComponent("input.jpg")
            try Data([1, 2, 3]).write(to: input)
            if index > 0 { Thread.sleep(forTimeInterval: 0.1) }
            return PreparedAlbumItem(.photo(input), scratch: scratch)
        }
        var item: PreparedAlbumItem? = try owned.next()!.1.get()
        check(FileManager.default.fileExists(atPath: root.appendingPathComponent("0/input.jpg").path), "Original remains available while its owner is retained for rendering")
        withExtendedLifetime(item) {}
        item = nil
        waitUntil { !FileManager.default.fileExists(atPath: root.appendingPathComponent("0").path) }
        checks.append("Rendered original's scratch is released independently")
        owned.stop()
        waitUntil { ownedProbe.snapshot.0 == 0 }
        waitUntil { (try? FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty) == true }
        checks.append("Stopping removes buffered originals and discards late download results")

        let empty = AlbumPreparationQueue<Int>(count: 0, check: {}, prepare: { $0 })
        check(try empty.next() == nil, "An empty queue finishes without downloading")
        empty.stop()
        let report: [String: Any] = ["passed": true, "checks": checks,
            "scope": "Production preparation queue with controlled slow/error/cancelled loaders and real temporary originals; no PhotoKit mocks claiming iCloud speed."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("PASS \(checks.count) album preparation checks")
    }
}
