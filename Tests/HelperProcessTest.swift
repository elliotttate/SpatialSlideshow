import Foundation
import Darwin

@main struct HelperProcessTest {
    static func main() throws {
        let args = CommandLine.arguments
        if args.count > 1 {
            setbuf(stdout, nil)
            if args[1] == "hang" {
                signal(SIGTERM, SIG_IGN)
                try String(getpid()).write(toFile: args[2], atomically: true, encoding: .utf8)
                print("model loading started")
                while true { Thread.sleep(forTimeInterval: 0.1) }
            }
            if args[1] == "fail" { print("ERROR: synthetic model failure"); exit(7) }
            print("completed synthetic model"); return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = URL(fileURLWithPath: args[0]), log = root.appendingPathComponent("helper.log")
        let diagnostics = root.appendingPathComponent("Diagnostics"), pidFile = root.appendingPathComponent("pid")
        var checks = 0
        func expect(_ condition: Bool, _ label: String) { precondition(condition, label); checks += 1 }
        func run(_ mode: String, timeout: Double = 2, cancelled: () -> Bool = { false }, progress: (String) -> Void = { _ in }) throws {
            try HelperProcess.run(executable, arguments: [mode, pidFile.path], log: log,
                                  environment: ProcessInfo.processInfo.environment, stage: "Creating the Photos 3D scene",
                                  timeout: timeout, heartbeat: 0.05, diagnostics: diagnostics, cancelled: cancelled, progress: progress)
        }
        try run("success")
        expect(try String(contentsOf: log, encoding: .utf8).contains("completed"), "Preserve successful output")
        do { try run("fail"); preconditionFailure("Expected failure") }
        catch {
            let error = error as NSError
            expect(error.localizedDescription.contains("exit 7"), "Explain failed helper exit")
            expect(error.localizedDescription.contains("synthetic model failure"), "Include useful helper error")
            let saved = URL(fileURLWithPath: error.userInfo["diagnosticLog"] as! String)
            try FileManager.default.removeItem(at: log)
            expect(FileManager.default.fileExists(atPath: saved.path), "Failure log survives scratch removal")
        }
        var updates: [String] = [], liveOutput = false
        var start = Date()
        do {
            try run("hang", timeout: 0.35, progress: { phase in
                updates.append(phase)
                if (try? String(contentsOf: log, encoding: .utf8).contains("model loading")) == true { liveOutput = true }
            })
            preconditionFailure("Expected timeout")
        } catch {
            expect((error as NSError).code == 2, "Distinct helper timeout")
            expect(error.localizedDescription.contains("Creating the Photos 3D scene"), "Name timed-out stage")
        }
        expect(Date().timeIntervalSince(start) < 3, "Hung child has a bounded deadline")
        expect(updates.count > 1 && liveOutput, "Progress updates and partial log available before completion")
        let pid = Int32(try String(contentsOf: pidFile, encoding: .utf8))!
        expect(kill(pid, 0) != 0, "Unresponsive helper is reaped")
        start = Date()
        do { try run("hang", cancelled: { Date().timeIntervalSince(start) > 0.2 }); preconditionFailure("Expected cancellation") }
        catch is CancellationError { expect(Date().timeIntervalSince(start) < 3, "Cancel promptly terminates a hung child") }
        try run("success")
        expect(try String(contentsOf: log, encoding: .utf8).contains("completed"), "Next item can run after a failed helper")
        print("PASS \(checks) helper progress, timeout, cancellation and retained diagnostics checks")
    }
}
