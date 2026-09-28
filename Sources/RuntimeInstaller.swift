import Foundation
import CryptoKit
import Darwin

/// Installs only the runtime needed by the selected local expansion engine.
/// Production has no dependency on Homebrew, developer tools, or a system Python.
enum RuntimeInstaller {
    static let pythonVersion = "3.12.14-20260924"
    static let pythonArchive = URL(string: "https://github.com/astral-sh/python-build-standalone/releases/download/20260924/cpython-3.12.14%2B20260924-aarch64-apple-darwin-install_only.tar.gz")!
    static let pythonSHA256 = "9763f43db2481a6af36af82ec40302aab7a73632f880129d07a6e81aec846277"
    static let pythonArchiveBytes: Int64 = 25_153_879
    static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Photos Spatial Slideshow", isDirectory: true)
    }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "SpatialSlideshow.ModelSetup", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    static func check(_ cancelled: () -> Bool) throws { if cancelled() { throw CancellationError() } }
    static func environment(python: URL? = nil) -> [String: String] {
        var result = ProcessInfo.processInfo.environment
        for key in ["PYTHONHOME", "PYTHONPATH", "PYTHONSTARTUP", "VIRTUAL_ENV", "CONDA_PREFIX", "HF_HUB_OFFLINE"] { result.removeValue(forKey: key) }
        result["PYTHONUNBUFFERED"] = "1"; result["PYTHONDONTWRITEBYTECODE"] = "1"
        result["PYTHONNOUSERSITE"] = "1"; result["PIP_NO_INPUT"] = "1"
        result["SPATIAL_MANAGED_SETUP"] = "1"
        result["PATH"] = (python.map { $0.deletingLastPathComponent().path + ":" } ?? "") + "/usr/bin:/bin:/usr/sbin:/sbin"
        return result
    }
    static func withInstallationLock<T>(at root: URL, cancelled: () -> Bool, progress: (String) -> Void,
                                        operation: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let descriptor = open(root.appendingPathComponent("installation.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw failure("Could not open the model installation folder. Check its permissions.") }
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        var notified = false
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN else { throw failure("Could not lock the model installation folder.") }
            try check(cancelled)
            if !notified { progress("Waiting for another model installation to finish…"); notified = true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        try check(cancelled)
        return try operation()
    }
    static func verifyDownload(_ url: URL, size: Int64, sha256: String) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.int64Value == size else {
            throw failure("The runtime download is incomplete. Retry to download it again.")
        }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty { hash.update(data: bytes) }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == sha256 else {
            throw failure("The runtime download failed its integrity check. Retry the download.")
        }
    }
    static func portablePython(root: URL = support, cancelled: () -> Bool, progress: (String) -> Void) throws -> URL {
        let manager = FileManager.default
        let runtimeRoot = root.appendingPathComponent("Python Runtime", isDirectory: true)
        let destination = runtimeRoot.appendingPathComponent(pythonVersion, isDirectory: true)
        let python = destination.appendingPathComponent("python/bin/python3.12")
        let receipt = destination.appendingPathComponent("verified-archive.txt")
        if manager.isExecutableFile(atPath: python.path),
           (try? String(contentsOf: receipt, encoding: .utf8)) == pythonSHA256 {
            let log = runtimeRoot.appendingPathComponent("runtime-check.log")
            do {
                try HelperProcess.run(python, arguments: ["-I", "-c", "import sys, ssl, venv, hashlib; assert sys.version_info[:2] == (3, 12)"],
                    log: log, environment: environment(python: python), stage: "Checking local model runtime", timeout: 30,
                    cancelled: cancelled, progress: progress)
                return python
            } catch is CancellationError { throw CancellationError() }
            catch { progress("Repairing the local model runtime…") }
        }
        try manager.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        let attributes = try manager.attributesOfFileSystem(forPath: runtimeRoot.path)
        guard ((attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0) >= 800 * 1024 * 1024 else {
            throw failure("At least 800 MB of free space is needed to install the local model runtime. Free some space, then retry.")
        }
        let staging = runtimeRoot.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }
        let archive = staging.appendingPathComponent("python.tar.gz")
        progress("Downloading the local model runtime · 25 MB…")
        do {
            try RuntimeDownload.fetch(pythonArchive, to: archive, maximumBytes: pythonArchiveBytes, cancelled: cancelled, progress: progress)
        } catch is CancellationError { throw CancellationError() }
        catch { throw failure("The local model runtime could not be downloaded: \(error.localizedDescription) Check your connection, then retry model setup.") }
        try verifyDownload(archive, size: pythonArchiveBytes, sha256: pythonSHA256)
        try check(cancelled)
        progress("Installing the local model runtime…")
        let unpacked = staging.appendingPathComponent("unpacked", isDirectory: true)
        try manager.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try HelperProcess.run(URL(fileURLWithPath: "/usr/bin/tar"), arguments: ["-xzf", archive.path, "-C", unpacked.path],
                              log: staging.appendingPathComponent("unpack.log"), environment: environment(), stage: "Unpacking local runtime",
                              timeout: 120, cancelled: cancelled, progress: progress)
        let candidate = unpacked.appendingPathComponent("python/bin/python3.12")
        try HelperProcess.run(candidate, arguments: ["-I", "-c", "import sys, ssl, venv, hashlib; assert sys.version_info[:2] == (3, 12)"],
                              log: staging.appendingPathComponent("check.log"), environment: environment(python: candidate), stage: "Checking local runtime",
                              timeout: 30, cancelled: cancelled, progress: progress)
        try check(cancelled)
        try pythonSHA256.write(to: unpacked.appendingPathComponent("verified-archive.txt"), atomically: true, encoding: .utf8)
        // Keep an incomplete previous installation until its replacement is verified.
        let backup = runtimeRoot.appendingPathComponent(".previous-\(UUID().uuidString)")
        let hadPrevious = manager.fileExists(atPath: destination.path)
        if hadPrevious { try manager.moveItem(at: destination, to: backup) }
        do { try manager.moveItem(at: unpacked, to: destination) }
        catch {
            if hadPrevious { try? manager.moveItem(at: backup, to: destination) }
            throw error
        }
        if hadPrevious { try? manager.removeItem(at: backup) }
        return python
    }
    static func ensure(backend: ExpansionBackend, tools: URL, override: String = "",
                       cancelled: () -> Bool, progress: (String) -> Void) throws -> URL {
        let drawThings = backend == .drawThingsFlux
        let helper = tools.appendingPathComponent(drawThings ? "ExpandPhotoDrawThings.py" : "ExpandPhotoKlein.py")
        let setup = tools.appendingPathComponent(drawThings ? "setup_drawthings.py" : "setup_klein.py")
        guard FileManager.default.isReadableFile(atPath: helper.path), FileManager.default.isReadableFile(atPath: setup.path) else {
            throw failure("The model installer is missing from this app. Download a complete copy of Spatial Slideshow.")
        }
        return try withInstallationLock(at: support.appendingPathComponent("Model Setup"), cancelled: cancelled, progress: progress) {
            let logs = support.appendingPathComponent("Diagnostics", isDirectory: true)
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            let log = logs.appendingPathComponent("Model-setup-\(UUID().uuidString).log")
            let existing = drawThings ? DrawThingsRuntime.pythonURL() : KleinRuntime.pythonURL(override: override)
            if let existing {
                do {
                    try HelperProcess.run(existing, arguments: [helper.path, "--check"], log: log,
                        environment: environment(python: existing), stage: "Checking \(backend.title) models", timeout: 90,
                        cancelled: cancelled, progress: progress)
                    return existing
                } catch is CancellationError { throw CancellationError() }
                catch {
                    if !drawThings && !override.isEmpty {
                        throw failure("The custom FLUX runtime could not be verified. Reset to Automatic in Settings to install a managed runtime. Details are in Diagnostics.")
                    }
                    progress("Repairing the missing \(backend.title) runtime or models…")
                }
            } else if !drawThings && !override.isEmpty {
                throw failure("The custom FLUX runtime is unavailable. Reset to Automatic in Settings to install it automatically.")
            }
            let python = try portablePython(cancelled: cancelled, progress: progress)
            try HelperProcess.run(python, arguments: ["-u", setup.path, "--python", python.path], log: log,
                environment: environment(python: python), stage: "Installing \(backend.title) · downloading required models",
                timeout: 14_400, heartbeat: 1, slowAfter: 14_400, cancelled: cancelled, progress: progress,
                liveOutputPrefixes: ["SETUP "], terminateProcessGroup: true)
            try check(cancelled)
            guard let installed = drawThings ? DrawThingsRuntime.pythonURL() : KleinRuntime.pythonURL() else {
                throw failure("The model installation did not finish. Retry from Settings; completed downloads will be reused.")
            }
            try HelperProcess.run(installed, arguments: [helper.path, "--check"], log: log,
                environment: environment(python: installed), stage: "Verifying \(backend.title) models", timeout: 90,
                cancelled: cancelled, progress: progress)
            progress("\(backend.title) is ready")
            return installed
        }
    }
}

/// URLSession handles TLS and redirects; the pinned digest is checked before execution.
private final class RuntimeDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var failure: Error?
    private var bytes: Int64 = 0
    private let destination: URL
    private let maximumBytes: Int64
    init(destination: URL, maximumBytes: Int64) { self.destination = destination; self.maximumBytes = maximumBytes }
    static func fetch(_ url: URL, to destination: URL, maximumBytes: Int64, cancelled: () -> Bool, progress: (String) -> Void) throws {
        let delegate = RuntimeDownload(destination: destination, maximumBytes: maximumBytes)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 900
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task = session.downloadTask(with: url); task.resume()
        var previous: Int64 = -1
        while true {
            if cancelled() { task.cancel(); throw CancellationError() }
            delegate.lock.lock()
            let done = delegate.finished, error = delegate.failure, count = delegate.bytes
            delegate.lock.unlock()
            if done { if let error { throw error }; return }
            let percent = count * 100 / max(1, maximumBytes)
            if percent != previous {
                progress("Downloading the local model runtime · \(percent)% of 25 MB")
                previous = percent
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.lock(); bytes = totalBytesWritten; lock.unlock()
        if totalBytesWritten > maximumBytes { downloadTask.cancel() }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 else {
                throw RuntimeInstaller.failure("The runtime download server did not return the expected file. Check your connection and retry.")
            }
            try FileManager.default.moveItem(at: location, to: destination)
        } catch { lock.lock(); failure = error; lock.unlock() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); if failure == nil { failure = error }; finished = true; lock.unlock()
    }
}
