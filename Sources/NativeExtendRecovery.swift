import Foundation

/// Cloud transport failures keep the current photo pending. A rate limit blocks
/// new requests across app launches, while playback continues from local clips.
enum NativeExtendRecovery {
    enum Reason: String, Codable { case network, rateLimit }
    struct State: Codable {
        let reason: Reason
        let retryAt: TimeInterval
        let rateLimitCount: Int
        let networkFailures: Int
    }

    static var stateURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Photos Spatial Slideshow/Native Extend Service.json")
    }

    static func reason(_ error: Error) -> Reason? {
        let value = error as NSError
        let text = (value.localizedDescription + " " + (value.userInfo["output"] as? String ?? "")).lowercased()
        if text.contains("deniedduetouserdeviceratelimit") || text.contains("inferenceerror::ratelimited") { return .rateLimit }
        if text.contains("privatecloudcomputeerror: networkfailure") || text.contains("socket is not connected") { return .network }
        return nil
    }

    static func readState(at url: URL) -> State? {
        guard let data = try? Data(contentsOf: url), let state = try? JSONDecoder().decode(State.self, from: data),
              state.retryAt.isFinite, state.retryAt >= 0, state.rateLimitCount >= 0, state.networkFailures >= 0 else { return nil }
        return state
    }

    @discardableResult
    static func record(_ reason: Reason, at url: URL, now: TimeInterval) throws -> State {
        let previous = readState(at: url)
        let rateCount = min(3, (previous?.rateLimitCount ?? 0) + (reason == .rateLimit ? 1 : 0))
        let networkCount = min(4, (previous?.networkFailures ?? 0) + (reason == .network ? 1 : 0))
        // Apple does not supply a reset time in the observed failure. These are
        // conservative app-chosen delays, not a claimed server reset schedule.
        let delay: TimeInterval = reason == .rateLimit
            ? [900, 1800, 3600][max(0, rateCount - 1)]
            : [5, 15, 60, 300][max(0, networkCount - 1)]
        let state = State(reason: reason, retryAt: max(previous?.retryAt ?? 0, now + delay),
                          rateLimitCount: rateCount, networkFailures: networkCount)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
        return state
    }

    static func message(_ state: State, now: TimeInterval) -> String {
        let seconds = max(0, Int(ceil(state.retryAt - now)))
        let countdown = String(format: "%d:%02d", seconds / 60, seconds % 60)
        switch state.reason {
        case .network:
            return "Apple’s Extend connection dropped. Retrying this photo in \(countdown). Prepared photos keep playing."
        case .rateLimit:
            return "Apple has temporarily limited Extend requests. New requests paused; next check in \(countdown). Prepared photos keep playing."
        }
    }

    static func userError(_ error: Error) -> NSError {
        let original = error as NSError
        var info = original.userInfo
        info[NSUnderlyingErrorKey] = original
        let detail = (original.userInfo["output"] as? String ?? original.localizedDescription).lowercased()
        let message: String
        if detail.contains("open the original apple photos") || detail.contains("photos closed") {
            message = "Open Apple Photos, then retry the album. Previously prepared photos are saved."
        } else if detail.contains("operation not permitted") || detail.contains("entitlement") {
            message = "Apple Photos Extend was not authorized. Check the research setup and keep original Photos open. See Diagnostics for details."
        } else {
            message = "Apple Photos Extend could not prepare this photo. See Diagnostics for the full error; previously prepared photos are saved."
        }
        info[NSLocalizedDescriptionKey] = message
        return NSError(domain: "SpatialSlideshow.NativeExtend", code: original.code, userInfo: info)
    }

    static func run<Value>(at url: URL = stateURL, check: () throws -> Void,
                           progress: (String) -> Void,
                           now: () -> TimeInterval = { Date().timeIntervalSince1970 },
                           wait: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                           operation: () throws -> Value) throws -> Value {
        while true {
            try check()
            var lastSecond = -1
            while let state = readState(at: url), state.retryAt > now() {
                try check()
                let second = Int(ceil(state.retryAt - now()))
                if second != lastSecond { progress(message(state, now: now())); lastSecond = second }
                wait(min(0.2, max(0, state.retryAt - now())))
            }
            try check()
            do {
                let value = try operation()
                try? FileManager.default.removeItem(at: url)
                return value
            } catch is CancellationError { throw CancellationError() }
            catch {
                try check()
                guard let reason = reason(error) else { throw userError(error) }
                // Persist before allowing another request. Failure to save the
                // cooldown must stop this preparation, never ignore the limit.
                do { try record(reason, at: url, now: now()) }
                catch {
                    throw NSError(domain: "SpatialSlideshow.NativeExtend", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "Extend preparation stopped because its retry state could not be saved. Free disk space and retry.",
                        NSUnderlyingErrorKey: error])
                }
            }
        }
    }
}
