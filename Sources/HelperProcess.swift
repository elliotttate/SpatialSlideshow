import Foundation
import Darwin

/// Keep helper output on disk while it runs. A hung model must not block the
/// preparation queue forever, and its log must survive scratch cleanup.
enum HelperProcess {
    static func run(_ executable: URL, arguments: [String], log: URL,
                    environment: [String: String], stage: String,
                    timeout: TimeInterval = 180, heartbeat: TimeInterval = 5, slowAfter: TimeInterval = 30,
                    diagnostics: URL? = nil, cancelled: () -> Bool,
                    progress: (String) -> Void, liveOutputPrefixes: [String] = [], terminateProcessGroup: Bool = false) throws {
        if cancelled() { throw CancellationError() }
        try Data().write(to: log)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        let task = Process()
        task.executableURL = executable; task.arguments = arguments
        task.environment = environment; task.standardOutput = output; task.standardError = output
        let start = ProcessInfo.processInfo.systemUptime
        var nextUpdate = start + heartbeat
        progress(stage + "…")
        do { try task.run() }
        catch {
            throw NSError(domain: "SpatialSlideshow.Helper", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "\(stage) could not start. Reinstall the app if this continues.",
                NSUnderlyingErrorKey: error])
        }
        func stopChild() {
            guard task.isRunning else { return }
            // Managed installers put themselves and pip/download children in
            // their own process group. Never signal the app's process group.
            let group = terminateProcessGroup && getpgid(task.processIdentifier) == task.processIdentifier
                ? task.processIdentifier : nil
            if let group { kill(-group, SIGTERM) } else { task.terminate() }
            let deadline = ProcessInfo.processInfo.systemUptime + 1
            while task.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if let group { kill(-group, SIGKILL) }
            else if task.isRunning { kill(task.processIdentifier, SIGKILL) }
            task.waitUntilExit()
        }
        var timedOut = false
        while task.isRunning {
            if cancelled() { stopChild(); throw CancellationError() }
            let now = ProcessInfo.processInfo.systemUptime
            if now - start >= timeout { timedOut = true; stopChild(); break }
            if now >= nextUpdate {
                let elapsed = Int(now - start)
                let slow = Double(elapsed) >= slowAfter ? " · Taking longer than usual; timeout at \(Int(timeout))s" : ""
                var detail: String?
                if !liveOutputPrefixes.isEmpty, let reader = try? FileHandle(forReadingFrom: log) {
                    defer { try? reader.close() }
                    let size = (try? reader.seekToEnd()) ?? 0
                    try? reader.seek(toOffset: size > 8192 ? size - 8192 : 0)
                    if let bytes = try? reader.readToEnd(), let text = String(data: bytes, encoding: .utf8) {
                        let line = text.components(separatedBy: .newlines).last { line in
                            liveOutputPrefixes.contains { line.hasPrefix($0) }
                        }
                        if let line, let prefix = liveOutputPrefixes.first(where: { line.hasPrefix($0) }) {
                            detail = String(line.dropFirst(prefix.count))
                        }
                    }
                }
                progress("\(detail ?? stage) · \(elapsed)s elapsed\(slow)")
                nextUpdate = now + heartbeat
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        task.waitUntilExit()
        if cancelled() { throw CancellationError() }
        guard timedOut || task.terminationStatus != 0 else { return }
        let reader = try? FileHandle(forReadingFrom: log)
        let size = (try? reader?.seekToEnd()) ?? 0
        try? reader?.seek(toOffset: size > 8192 ? size - 8192 : 0)
        let tail = (try? reader?.readToEnd()).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        try? reader?.close()
        var info: [String: Any] = ["helper": executable.lastPathComponent, "stage": stage, "output": tail]
        if let diagnostics {
            try? FileManager.default.createDirectory(at: diagnostics, withIntermediateDirectories: true)
            let saved = diagnostics.appendingPathComponent("\(executable.lastPathComponent)-\(UUID().uuidString).log")
            if (try? FileManager.default.copyItem(at: log, to: saved)) != nil { info["diagnosticLog"] = saved.path }
        }
        let detail = tail.components(separatedBy: .newlines).last(where: { $0.contains("ERROR:") })
        info[NSLocalizedDescriptionKey] = timedOut
            ? "\(stage) did not finish and was stopped after \(Int(timeout)) seconds. Try again, or reduce output resolution / turn off edge expansion."
            : "\(stage) failed (\(task.terminationReason == .uncaughtSignal ? "signal" : "exit") \(task.terminationStatus)). \(detail.map { String($0.prefix(400)) } ?? "See Diagnostics for the helper log.")"
        throw NSError(domain: "SpatialSlideshow.Helper", code: timedOut ? 2 : 3, userInfo: info)
    }
}
