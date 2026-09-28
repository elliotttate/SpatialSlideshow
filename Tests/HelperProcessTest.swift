import Foundation
import Darwin

@main struct HelperProcessTest {
    static func main() throws {
        let args = CommandLine.arguments
        if args.count > 1 {
            setbuf(stdout, nil)
            if args[1] == "progress" {
                print("SETUP Downloading test runtime · 10%")
                Thread.sleep(forTimeInterval: 0.25)
                print("ignored non-setup noise")
                print("SETUP Verifying test runtime")
                Thread.sleep(forTimeInterval: 0.25)
                return
            }
            if args[1] == "managed-tree" {
                precondition(ProcessInfo.processInfo.environment["SPATIAL_MANAGED_SETUP"] == "1")
                // Mirror the managed Python installer: it owns an isolated
                // process group and children inherit that group.
                if getpgrp() != getpid() { precondition(setpgid(0, 0) == 0) }
                signal(SIGTERM, SIG_IGN)
                var descendant: pid_t = 0
                var spawnArguments = [strdup(args[0]), strdup("descendant"), nil]
                defer { for pointer in spawnArguments { free(pointer) } }
                var spawnEnvironment: [UnsafeMutablePointer<CChar>?] = [nil]
                // No spawn group attributes: the descendant inherits this
                // installer's group, as Python's subprocess children do.
                precondition(posix_spawn(&descendant, args[0], nil, nil, &spawnArguments, &spawnEnvironment) == 0)
                precondition(getpgid(descendant) == getpgrp())
                try String(getpid()).write(toFile: args[2], atomically: true, encoding: .utf8)
                try String(descendant).write(toFile: args[2] + ".descendant", atomically: true, encoding: .utf8)
                print("SETUP Synthetic installer child running")
                while true { Thread.sleep(forTimeInterval: 0.1) }
            }
            if args[1] == "descendant" {
                signal(SIGTERM, SIG_IGN)
                while true { Thread.sleep(forTimeInterval: 0.1) }
            }
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
        updates = []
        try HelperProcess.run(executable, arguments: ["progress"], log: log,
                              environment: ProcessInfo.processInfo.environment, stage: "Installing test runtime",
                              timeout: 3, heartbeat: 0.05, cancelled: { false }, progress: { updates.append($0) },
                              liveOutputPrefixes: ["SETUP "])
        expect(updates.contains(where: { $0.contains("Downloading test runtime") }), "Live installer download progress reaches the UI before exit")
        expect(updates.contains(where: { $0.contains("Verifying test runtime") }), "Live installer progress advances to its next stage")
        expect(!updates.contains(where: { $0.contains("ignored non-setup noise") || $0.contains("SETUP ") }), "Live output strips its prefix and ignores unrelated log output")

        var managedEnvironment = ProcessInfo.processInfo.environment
        managedEnvironment["SPATIAL_MANAGED_SETUP"] = "1"
        let descendantFile = URL(fileURLWithPath: pidFile.path + ".descendant")
        start = Date()
        var cancelledManagedTree = false
        do {
            try HelperProcess.run(executable, arguments: ["managed-tree", pidFile.path], log: log,
                                  environment: managedEnvironment, stage: "Installing synthetic runtime", timeout: 4,
                                  heartbeat: 0.05, cancelled: {
                                      FileManager.default.fileExists(atPath: descendantFile.path) || Date().timeIntervalSince(start) > 2
                                  }, progress: { _ in }, liveOutputPrefixes: ["SETUP "], terminateProcessGroup: true)
            preconditionFailure("Expected managed-tree cancellation")
        } catch is CancellationError { cancelledManagedTree = true }
        let managedPID = Int32(try String(contentsOf: pidFile, encoding: .utf8))!
        let descendantPID = Int32(try String(contentsOf: descendantFile, encoding: .utf8))!
        // Avoid leaking a synthetic child even if a regression makes the
        // assertions fail. These exact PIDs belong to this test only.
        defer { if kill(descendantPID, 0) == 0 { kill(descendantPID, SIGKILL) } }
        let reapedDeadline = Date().addingTimeInterval(2)
        while kill(descendantPID, 0) == 0 && Date() < reapedDeadline { Thread.sleep(forTimeInterval: 0.02) }
        let childGone = kill(descendantPID, 0) != 0
        if !childGone { kill(descendantPID, SIGKILL) }
        expect(cancelledManagedTree, "Managed installer cancellation preserves CancellationError")
        expect(kill(managedPID, 0) != 0, "Cancelled managed installer is reaped")
        expect(childGone, "Cancelling a managed installer also terminates its subprocess descendant")
        expect(Date().timeIntervalSince(start) < 4, "Managed process-tree cancellation stays bounded")
        print("PASS \(checks) helper progress, timeout, cancellation and retained diagnostics checks")
    }
}
