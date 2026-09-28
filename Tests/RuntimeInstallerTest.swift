import Foundation
import CryptoKit
import Darwin

@main struct RuntimeInstallerTest {
    static func main() throws {
        let args = CommandLine.arguments
        let integration = args.contains("--bootstrap-integration")
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("Spatial Runtime Test \(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        var checks: [String] = []
        func expect(_ condition: Bool, _ description: String) {
            guard condition else { fputs("FAIL: \(description)\n", stderr); exit(1) }
            checks.append(description)
        }
        func expectFailure(_ description: String, containing: String, _ operation: () throws -> Void) {
            do { try operation(); preconditionFailure(description) }
            catch { expect(containing.isEmpty || error.localizedDescription.contains(containing), description) }
        }

        let fixture = root.appendingPathComponent("download.bin")
        // Larger than one hash read so corruption after the first chunk is detected.
        var bytes = Data(repeating: 0xA5, count: 1024 * 1024 + 19)
        bytes[bytes.count - 1] = 0x31
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        try bytes.write(to: fixture)
        try RuntimeInstaller.verifyDownload(fixture, size: Int64(bytes.count), sha256: digest)
        expect(true, "A complete download with its expected digest passes")
        try bytes.dropLast().write(to: fixture)
        expectFailure("Truncated downloads fail before extraction", containing: "incomplete") {
            try RuntimeInstaller.verifyDownload(fixture, size: Int64(bytes.count), sha256: digest)
        }
        bytes[bytes.count - 1] ^= 1
        try bytes.write(to: fixture)
        expectFailure("Same-size corruption after the first hash chunk fails", containing: "integrity") {
            try RuntimeInstaller.verifyDownload(fixture, size: Int64(bytes.count), sha256: digest)
        }
        expectFailure("A missing download fails", containing: "") {
            try RuntimeInstaller.verifyDownload(root.appendingPathComponent("missing"), size: 1, sha256: digest)
        }

        let python = root.appendingPathComponent("Python Runtime/bin/python3.12")
        let environment = RuntimeInstaller.environment(python: python)
        for key in ["PYTHONHOME", "PYTHONPATH", "PYTHONSTARTUP", "VIRTUAL_ENV", "CONDA_PREFIX", "HF_HUB_OFFLINE"] {
            expect(ProcessInfo.processInfo.environment[key] == "runtime-test-poison", "Runner supplied an inherited \(key) override")
            expect(environment[key] == nil, "Managed setup removes inherited \(key)")
        }
        expect(environment["PATH"] == python.deletingLastPathComponent().path + ":/usr/bin:/bin:/usr/sbin:/sbin", "Managed Python precedes only system tools on PATH")
        expect(RuntimeInstaller.environment()["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin", "Bootstrap does not search Homebrew or developer PATH")
        expect(environment["PYTHONDONTWRITEBYTECODE"] == "1", "Setup cannot create bytecode inside the signed app")
        expect(environment["PYTHONNOUSERSITE"] == "1", "User site packages cannot alter managed setup")
        expect(environment["PIP_NO_INPUT"] == "1" && environment["PYTHONUNBUFFERED"] == "1", "Setup is noninteractive and reports unbuffered progress")
        expect(environment["SPATIAL_MANAGED_SETUP"] == "1", "Managed installer process-group cancellation is enabled")

        let lockRoot = root.appendingPathComponent("Contended Setup", isDirectory: true)
        try manager.createDirectory(at: lockRoot, withIntermediateDirectories: true)
        let descriptor = open(lockRoot.appendingPathComponent("installation.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        precondition(descriptor >= 0 && flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        var operationRan = false, lockMessages: [String] = []
        let began = Date()
        do {
            try RuntimeInstaller.withInstallationLock(at: lockRoot, cancelled: { Date().timeIntervalSince(began) > 0.25 }, progress: { lockMessages.append($0) }) {
                operationRan = true
            }
            preconditionFailure("Contended installation should be cancellable")
        } catch is CancellationError {
            expect(Date().timeIntervalSince(began) < 2, "Cancelling while another installation owns the lock is responsive")
        }
        expect(!operationRan, "A cancelled lock waiter never starts installation")
        expect(lockMessages.count == 1 && lockMessages[0].contains("another model installation"), "Lock contention explains the wait once")
        flock(descriptor, LOCK_UN); close(descriptor)
        let answer = try RuntimeInstaller.withInstallationLock(at: lockRoot, cancelled: { false }, progress: { _ in }) { 42 }
        expect(answer == 42, "Installation can start after a cancelled wait")
        do {
            try RuntimeInstaller.withInstallationLock(at: lockRoot, cancelled: { true }, progress: { _ in }) { operationRan = true }
            preconditionFailure("Pre-cancelled install should not run")
        } catch is CancellationError { expect(!operationRan, "Pre-cancelled installation does not run under a free lock") }
        expect(try RuntimeInstaller.withInstallationLock(at: lockRoot, cancelled: { false }, progress: { _ in }) { true }, "Cancellation releases the acquired lock")

        var integrationProgress: [String] = []
        if integration {
            func bootstrap() throws -> URL {
                try RuntimeInstaller.portablePython(root: root, cancelled: { false }, progress: { phase in
                    integrationProgress.append(phase)
                    print(phase)
                })
            }
            let installed = try bootstrap()
            let log = root.appendingPathComponent("python-validation.log")
            let validation = """
            import json, sys, ssl, urllib.request, venv, hashlib, ctypes, sqlite3
            assert sys.version_info[:2] == (3, 12)
            assert ssl.create_default_context().cert_store_stats()['x509_ca'] > 0
            with urllib.request.urlopen('https://github.com/astral-sh/python-build-standalone', timeout=30) as result:
                assert result.status == 200
            print(json.dumps({'python': sys.version.split()[0], 'tls_verified': True, 'prefix': sys.prefix}))
            """
            try HelperProcess.run(installed, arguments: ["-I", "-c", validation], log: log,
                                  environment: RuntimeInstaller.environment(python: installed), stage: "Checking isolated Python TLS/imports",
                                  timeout: 60, cancelled: { false }, progress: { _ in })
            let verified = try JSONSerialization.jsonObject(with: Data(contentsOf: log)) as! [String: Any]
            expect(verified["tls_verified"] as? Bool == true, "Fresh portable Python verifies HTTPS and loads required standard modules")
            let prefix = URL(fileURLWithPath: verified["prefix"] as! String).resolvingSymlinksInPath().path
            expect(prefix.hasPrefix(root.resolvingSymlinksInPath().path + "/"), "Portable Python is isolated under the temporary test directory")
            expect(!installed.path.contains(".install-"), "Verified Python is published at its stable path")
            let receipt = installed.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("verified-archive.txt")
            expect(try String(contentsOf: receipt, encoding: .utf8) == RuntimeInstaller.pythonSHA256, "Published runtime receipt matches the pinned archive")
            let reuseStart = integrationProgress.count
            expect(try bootstrap() == installed, "An intact portable installation is reused")
            expect(!integrationProgress.dropFirst(reuseStart).contains(where: { $0.contains("Downloading") }), "Reuse performs no runtime download")

            // Both repair cases affect only this test's runtime. Each repair may
            // download the pinned 25 MB Python archive again; no model is fetched.
            try "incomplete-receipt".write(to: receipt, atomically: true, encoding: .utf8)
            expect(try bootstrap() == installed, "An incomplete receipt is repaired at the stable installation path")
            expect(try String(contentsOf: receipt, encoding: .utf8) == RuntimeInstaller.pythonSHA256, "Repair restores a verified runtime receipt")
            // Keep the valid receipt and executable bit, but make interpreter
            // execution fail. A mere isExecutableFile check must not pass this.
            try manager.removeItem(at: installed)
            try Data("#!/bin/sh\nexit 73\n".utf8).write(to: installed)
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installed.path)
            let repairStart = integrationProgress.count
            expect(try bootstrap() == installed, "A broken interpreter is repaired despite its valid receipt")
            expect(integrationProgress.dropFirst(repairStart).contains(where: { $0.contains("Repairing") }), "Broken-interpreter repair is visible in progress")
            try HelperProcess.run(installed, arguments: ["-I", "-c", "import ssl, venv; print('repaired')"], log: log,
                                  environment: RuntimeInstaller.environment(python: installed), stage: "Checking repaired Python",
                                  timeout: 30, cancelled: { false }, progress: { _ in })
            expect(try String(contentsOf: log, encoding: .utf8).contains("repaired"), "The repaired interpreter runs successfully")
            let leftovers = try manager.contentsOfDirectory(atPath: root.appendingPathComponent("Python Runtime").path)
            expect(!leftovers.contains(where: { $0.hasPrefix(".install-") || $0.hasPrefix(".previous-") }), "Successful bootstrap and repairs clean owned staging/backups")
        }

        let report: [String: Any] = ["passed": true, "checks": checks, "bootstrapIntegration": integration,
            "scope": integration ? "Isolated Python bootstrap, HTTPS, reuse, and repair only; no model download, Photos library, or private inference. Not a clean-Mac claim." : "Synthetic checksum, environment, and installation-lock tests; no downloads or photo access.",
            "integrationProgress": integrationProgress]
        if let position = args.firstIndex(of: "--report"), args.indices.contains(position + 1) {
            let destination = URL(fileURLWithPath: args[position + 1])
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: destination)
        }
        print("PASS \(checks.count) runtime installer checks" + (integration ? " including isolated bootstrap integration" : " (offline synthetic scope)"))
    }
}
