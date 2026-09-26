import Foundation

@main struct StorageRecoveryTest {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
        let lowDisk = NSError(domain: "CloudPhotoLibraryErrorDomain", code: 1005)
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message); checks += 1
        }
        check(StorageRecovery.isOutOfSpace(lowDisk), "Recognize the real Photos failure")
        check(StorageRecovery.isOutOfSpace(NSError(domain: "wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: lowDisk])), "Unwrap storage errors")
        check(StorageRecovery.isOutOfSpace(NSError(domain: NSPOSIXErrorDomain, code: 28)), "Recognize local ENOSPC")
        check(StorageRecovery.isOutOfSpace(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)), "Recognize failed file writes")
        check(!StorageRecovery.isOutOfSpace(NSError(domain: NSURLErrorDomain, code: -1005)), "Do not confuse network error -1005 with Photos error 1005")

        var attempts = 0, messages: [String?] = [], waited: TimeInterval = 0
        let value = try StorageRecovery.run(at: root, retryDelay: 0.5, check: {}, blocked: { messages.append($0) }, wait: { waited += $0 }) {
            attempts += 1
            if attempts <= 2 { throw lowDisk }
            return "downloaded original"
        }
        check(value == "downloaded original" && attempts == 3, "Retry the same item until its original is available")
        check(abs(waited - 1) < 0.001, "Back off between requests instead of hammering Photos")
        check(messages.count == 3 && messages[0]?.contains("disk nearly full") == true && messages[2] == nil, "Show and clear the blockage")

        var cancelled = false, cancelledAttempts = 0
        do {
            let _: Int = try StorageRecovery.run(at: root, check: { if cancelled { throw CancellationError() } }, blocked: { _ in }, wait: { _ in cancelled = true }) {
                cancelledAttempts += 1; throw lowDisk
            }
            preconditionFailure("Expected cancellation")
        } catch is CancellationError { check(cancelledAttempts == 1, "Stop interrupts retry without another request") }

        var missingAttempts = 0
        do {
            let _: Int = try StorageRecovery.run(at: root, check: {}, blocked: { _ in preconditionFailure("No storage warning for missing asset") }) {
                missingAttempts += 1; throw NSError(domain: "missing", code: 42)
            }
            preconditionFailure("Expected missing item")
        } catch { check(missingAttempts == 1, "Unrelated permanent errors still let the album continue") }

        // Exercise the actual bounded producer: a disk blockage must not finish
        // the album or discard all 618 assets as unavailable.
        let gate = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var storageFreed = false, requests = 0
        let queue = AlbumPreparationQueue<Int>(count: 618, concurrentLoads: 1, orderGrace: 0, check: {}) { index in
            try StorageRecovery.run(at: root, retryDelay: 0.01, check: {}, blocked: { _ in }, wait: { _ in started.signal(); gate.wait() }) {
                lock.lock(); requests += 1; let available = storageFreed; lock.unlock()
                if index == 0 && !available { throw lowDisk }
                return index
            }
        }
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            var indexes: [Int] = []
            while let (index, result) = try! queue.next() {
                precondition(try! result.get() == index); indexes.append(index)
            }
            precondition(indexes.count == 618 && Set(indexes).count == 618)
            done.signal()
        }
        precondition(started.wait(timeout: .now() + 3) == .success)
        lock.lock(); check(requests == 1, "A storage failure does not skip the rest of the album"); storageFreed = true; lock.unlock()
        gate.signal()
        check(done.wait(timeout: .now() + 5) == .success, "Freeing space resumes all 618 queued items exactly once")
        queue.stop()
        print("PASS \(checks) storage recovery checks (simulated storage failures; no Photos library access)")
    }
}
