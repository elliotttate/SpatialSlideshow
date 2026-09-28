import Foundation

@main struct NativeExtendRecoveryTest {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("service.json")
        let network = NSError(domain: "SpatialSlideshow.Helper", code: 3, userInfo: [
            "output": "ERROR: InferenceError::internalError::PrivateCloudComputeError: networkFailure (POSIXErrorCode(rawValue: 57): Socket is not connected)"])
        let limited = NSError(domain: "SpatialSlideshow.Helper", code: 3, userInfo: [
            "output": "ERROR: InferenceError::rateLimited::PrivateCloudComputeError: deniedDueToUserDeviceRateLimit"])
        let denied = NSError(domain: "SpatialSlideshow.Helper", code: 3, userInfo: ["output":"ERROR: Operation not permitted: missing entitlement"])
        var checks = 0
        func expect(_ condition: Bool, _ label: String) { precondition(condition,label); checks += 1 }
        expect(NativeExtendRecovery.reason(network) == .network,"Recognize the actual Photo 2 failure in helper output")
        expect(NativeExtendRecovery.reason(limited) == .rateLimit,"Recognize device quota independently of network failures")
        expect(NativeExtendRecovery.reason(denied) == nil,"Never retry missing authorization as a connection failure")

        var clock: Double = 1000, calls: [Double] = [], messages: [String] = []
        let value = try NativeExtendRecovery.run(at: state, check: {}, progress: { messages.append($0) }, now: { clock }, wait: { clock += $0 }) {
            calls.append(clock)
            if calls.count <= 2 { throw network }
            return "same-photo"
        }
        expect(value == "same-photo" && calls.count == 3,"Retry the same operation, without marking a photo skipped")
        expect(calls[1]-calls[0] >= 5 && calls[2]-calls[1] >= 15,"Network retries back off")
        expect(messages.contains { $0.contains("connection dropped") && $0.contains("Retrying this photo") },"Readable retry progress")
        expect(!FileManager.default.fileExists(atPath: state.path),"Successful cloud request clears cooldown")

        clock = 2000; calls = []
        do {
            let _: String = try NativeExtendRecovery.run(at: state, check: { if calls.count == 1 && clock > 2000.3 { throw CancellationError() } }, progress: { _ in }, now: { clock }, wait: { clock += $0 }) {
                calls.append(clock); throw limited
            }
            preconditionFailure("Expected Stop during cooldown")
        } catch is CancellationError { }
        expect(calls.count == 1,"Rate limiting stops new submissions instead of walking the album")
        let saved = NativeExtendRecovery.readState(at: state)!
        expect(saved.retryAt == 2900 && saved.reason == .rateLimit,"Persist a fifteen minute cooldown")
        var cancelledChecks = 0
        do {
            let _: String = try NativeExtendRecovery.run(at: state, check: { cancelledChecks += 1; if cancelledChecks > 3 { throw CancellationError() } }, progress: { _ in }, now: { clock }, wait: { clock += $0 }) {
                preconditionFailure("A fresh session must not bypass a persisted cooldown")
            }
        } catch is CancellationError { }
        expect(cancelledChecks == 4,"Stop is responsive during a persisted cooldown")

        clock = 2900
        let second = try NativeExtendRecovery.record(.rateLimit,at:state,now:clock)
        expect(second.retryAt == 4700,"Another denial extends the wait to thirty minutes")
        clock = 4700
        let third = try NativeExtendRecovery.record(.rateLimit,at:state,now:clock)
        expect(third.retryAt == 8300,"Further denial extends the wait to one hour")
        let next: String = try NativeExtendRecovery.run(at: state,check:{},progress:{_ in},now:{clock},wait:{clock += $0}) {
            expect(clock >= 8300,"Do not submit before the cooldown expires")
            return "ready"
        }
        expect(next == "ready","Continue automatically after cooldown")

        var deniedCalls = 0
        do {
            let _: String = try NativeExtendRecovery.run(at:state,check:{},progress:{_ in}) {
                deniedCalls += 1; throw denied
            }
            preconditionFailure("Authorization failure must be reported")
        } catch {
            expect(deniedCalls == 1,"Do not loop on a permanent failure")
            expect(error.localizedDescription.contains("not authorized"),"Explain authorization failure plainly")
            expect((error as NSError).userInfo[NSUnderlyingErrorKey] != nil,"Retain full error for diagnostics")
        }
        print("PASS \(checks) native Extend recovery checks; no model requests were made")
    }
}
