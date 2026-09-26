import Foundation

@main
enum DisplaySleepInhibitorTest {
    static func main() throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pid = ProcessInfo.processInfo.processIdentifier
        var checks: [String] = []
        var snapshots: [[String: Any]] = []

        func expect(_ condition: @autoclosure () -> Bool, _ description: String) {
            guard condition() else { fatalError("FAIL: \(description)") }
            checks.append(description)
        }

        func pmset(_ argument: String) throws -> String {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["-g", argument]
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            expect(process.terminationStatus == 0, "pmset -g \(argument) succeeds")
            return String(decoding: output, as: UTF8.self)
        }

        func verifyAssertionCount(_ count: Int, _ state: String) throws {
            let deadline = Date().addingTimeInterval(3)
            var output = ""
            var matchingLines: [String] = []
            repeat {
                output = try pmset("assertions")
                matchingLines = output.components(separatedBy: .newlines).filter {
                    $0.contains("pid \(pid)(") &&
                    $0.contains("PreventUserIdleDisplaySleep") &&
                    $0.contains("Spatial Slideshow playback")
                }
                if matchingLines.count == count { break }
                Thread.sleep(forTimeInterval: 0.025)
            } while Date() < deadline
            snapshots.append(["state": state, "matchingAssertionCount": matchingLines.count,
                              "matchingAssertions": matchingLines, "pmset": output])
            expect(matchingLines.count == count, "\(state): \(count) real display-sleep assertion(s)")
        }

        let originalSettings = try pmset("custom")
        var inhibitor: DisplaySleepInhibitor? = DisplaySleepInhibitor()
        weak let weakInhibitor = inhibitor
        expect(!inhibitor!.isActive, "starts inactive")
        try verifyAssertionCount(0, "initial")
        inhibitor!.setPlaybackActive(false)
        try verifyAssertionCount(0, "inactive repeated")
        inhibitor!.setPlaybackActive(true)
        expect(inhibitor!.isActive, "activation reports active")
        try verifyAssertionCount(1, "playing")
        for _ in 0..<100 { inhibitor!.setPlaybackActive(true) }
        try verifyAssertionCount(1, "100 duplicate activations")
        inhibitor!.setPlaybackActive(false)
        expect(!inhibitor!.isActive, "pause reports inactive")
        try verifyAssertionCount(0, "paused")
        for _ in 0..<100 { inhibitor!.setPlaybackActive(false) }
        try verifyAssertionCount(0, "100 duplicate deactivations")
        inhibitor!.setPlaybackActive(true)
        try verifyAssertionCount(1, "resumed")
        inhibitor = nil
        expect(weakInhibitor == nil, "inhibitor deinitializes")
        try verifyAssertionCount(0, "deinitialized while playing")
        let finalSettings = try pmset("custom")
        expect(originalSettings == finalSettings, "system power preferences unchanged")
        let report: [String: Any] = [
            "passed": true, "checks": checks, "pid": pid, "snapshots": snapshots,
            "powerPreferencesUnchanged": originalSettings == finalSettings,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: folder.appendingPathComponent("display-sleep-inhibitor-test.json"))
        print("PASS: \(checks.count) checks; activation, duplicate calls, pause, resume, deinit, and unchanged power preferences")
    }
}
