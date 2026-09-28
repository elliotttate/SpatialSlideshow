import Foundation

@main
struct ScenePreparationWindowTest {
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelledValue = false
        private var resultValue: Result<Void, Error>?
        var cancelled: Bool {
            get { lock.lock(); defer { lock.unlock() }; return cancelledValue }
            set { lock.lock(); cancelledValue = newValue; lock.unlock() }
        }
        var result: Result<Void, Error>? {
            get { lock.lock(); defer { lock.unlock() }; return resultValue }
            set { lock.lock(); resultValue = newValue; lock.unlock() }
        }
    }
    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("ScenePreparationWindowTest-\(UUID().uuidString)")
        let fixture = root.appendingPathComponent("fixture")
        try manager.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        var buffers: [String: Any] = [:]
        for (name, components) in ["alphas": 1, "positions": 3, "scales": 3, "rotations": 4, "colors": 3] {
            let width = 64, height = components * 2, stride = width * 2
            buffers[name] = ["width": width, "height": height, "bytesPerRow": stride, "pixelFormat": 1_278_226_536]
            try Data(repeating: 1, count: stride * height).write(to: fixture.appendingPathComponent(name + ".bin"))
        }
        try JSONSerialization.data(withJSONObject: ["width": 1280, "height": 720, "buffers": buffers])
            .write(to: fixture.appendingPathComponent("scene.json"))
        let scenes = try (0..<7).map {
            try SceneCache.store(fixture, sourceIdentity: "window-\($0)", version: "test", root: root)
        }
        let window = ScenePreparationWindow()
        for url in scenes.prefix(6) {
            try window.waitForCapacity(check: {})
            let inserted = try window.retain(url: url, root: root)
            precondition(inserted)
        }
        precondition(window.isFull && window.count == 6, "Only six unseen scenes should be held")
        let duplicate = try window.retain(url: scenes[0], root: root)
        precondition(!duplicate, "Duplicate registration must not consume capacity")
        do {
            try window.retain(url: scenes[6], root: root)
            preconditionFailure("Window exceeded its six-entry limit")
        } catch { precondition(window.count == 6) }
        try SceneCache.trim(root: root, byteLimit: 0)
        precondition(scenes.prefix(6).allSatisfy { manager.fileExists(atPath: $0.path) }, "Queued scenes remain protected from eviction")
        precondition(!manager.fileExists(atPath: scenes[6].path), "Unqueued scenes remain subject to the cache limit")

        let released = DispatchSemaphore(value: 0), releaseStarted = DispatchSemaphore(value: 0), releaseState = State()
        DispatchQueue.global().async {
            releaseState.result = Result {
                try window.waitForCapacity {
                    _ = window.isFull // Confirms callback is outside the condition lock.
                    releaseStarted.signal()
                }
            }
            released.signal()
        }
        precondition(releaseStarted.wait(timeout: .now() + 1) == .success)
        precondition(released.wait(timeout: .now() + 0.05) == .timedOut, "A full window blocks only its worker")
        let releaseStart = Date()
        window.release(url: scenes[0])
        precondition(Date().timeIntervalSince(releaseStart) < 0.1, "Renderer/main-thread release must not wait for the producer")
        precondition(released.wait(timeout: .now() + 1) == .success, "Releasing a loaded scene wakes preparation")
        try releaseState.result!.get()
        try SceneCache.trim(root: root, byteLimit: 0)
        precondition(!manager.fileExists(atPath: scenes[0].path), "Released scenes can be evicted")
        let refill = try SceneCache.store(fixture, sourceIdentity: "refill", version: "test", root: root)
        try window.retain(url: refill, root: root)

        let cancelled = DispatchSemaphore(value: 0), cancelStarted = DispatchSemaphore(value: 0), cancelState = State()
        DispatchQueue.global().async {
            cancelState.result = Result {
                try window.waitForCapacity {
                    cancelStarted.signal()
                    if cancelState.cancelled { throw CancellationError() }
                }
            }
            cancelled.signal()
        }
        precondition(cancelStarted.wait(timeout: .now() + 1) == .success)
        cancelState.cancelled = true
        precondition(cancelled.wait(timeout: .now() + 0.5) == .success, "Cancellation wakes a full window promptly")
        guard case .failure(let cancelError) = cancelState.result, cancelError is CancellationError else {
            preconditionFailure("Expected cancellation")
        }

        let cleared = DispatchSemaphore(value: 0), clearStarted = DispatchSemaphore(value: 0), clearState = State()
        DispatchQueue.global().async {
            clearState.result = Result { try window.waitForCapacity { clearStarted.signal() } }
            cleared.signal()
        }
        precondition(clearStarted.wait(timeout: .now() + 1) == .success)
        window.clear()
        precondition(cleared.wait(timeout: .now() + 1) == .success)
        guard case .failure(let clearError) = clearState.result, clearError is CancellationError else {
            preconditionFailure("Clear must invalidate the previous producer's wait")
        }
        precondition(!window.isFull && window.count == 0)
        try SceneCache.trim(root: root, byteLimit: 0)
        precondition(!manager.fileExists(atPath: refill.path), "Clear releases all disk leases")
        try window.waitForCapacity(check: {})
        print("PASS bounded six-scene window, cache protection, duplicate registration, nonblocking release, cancellation and clear")
    }
}
