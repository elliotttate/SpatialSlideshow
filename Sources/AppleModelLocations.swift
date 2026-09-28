import Foundation
import Darwin

/// Both native pipelines use the same macOS active-asset resolver as first-run
/// setup, so an OS update leaving two asset versions cannot change their choice.
enum AppleModelLocations {
    private struct Check: Decodable {
        let ready: Bool
        let message: String
        let models: [String: String]?
    }

    private static func installed(_ kind: String) throws -> [String: String] {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let helper = executable.deletingLastPathComponent().appendingPathComponent("AppleModelSetup")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw failure("The Apple model setup helper is missing. Reinstall Spatial Slideshow from the complete app download.")
        }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("spatial-model-check-\(UUID().uuidString).json")
        guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw failure("Could not create a temporary file while checking Apple Photos models. Check available disk space and retry.")
        }
        defer { try? FileManager.default.removeItem(at: output) }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = helper
        process.arguments = ["--check", kind]
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate()
            let cancelDeadline = ProcessInfo.processInfo.systemUptime + 1
            while process.isRunning && ProcessInfo.processInfo.systemUptime < cancelDeadline { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw failure("macOS did not finish checking its Photos models. Open Photos, finish any model setup, and retry.")
        }
        process.waitUntilExit()
        let data = try Data(contentsOf: output)
        guard let result = try? JSONDecoder().decode(Check.self, from: data) else {
            throw failure("The Apple model setup helper returned an unreadable result. Reinstall the complete app or check Diagnostics.")
        }
        guard process.terminationStatus == 0, result.ready, let models = result.models else { throw failure(result.message) }
        // The helper may only resolve registered Apple assets, never a model
        // from a developer's home directory or an untrusted environment value.
        guard models.values.allSatisfy({ $0.hasPrefix("/System/Library/AssetsV2/") }) else {
            throw failure("macOS returned a model outside its registered Photos asset directory.")
        }
        return models
    }

    static func reframe() throws -> (joint: URL, fov: URL) {
        let models = try installed("reframe")
        guard let joint = models["joint"], let fov = models["fov"] else { throw failure("The Apple Reframe model pair is incomplete.") }
        return (URL(fileURLWithPath: joint), URL(fileURLWithPath: fov))
    }

    static func cleanupRoot() throws -> URL {
        let models = try installed("cleanup")
        guard let root = models["root"] else { throw failure("The Apple Fast Clean Up model pair is incomplete.") }
        return URL(fileURLWithPath: root)
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "AppleModelSetup", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
