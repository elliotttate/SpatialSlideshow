import Foundation

/// Low storage is a session blockage, not hundreds of missing album items.
enum StorageRecovery {
    static func isOutOfSpace(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        // Limit traversal in case a framework supplies a cyclic error chain.
        for _ in 0..<12 {
            guard let value = current else { break }
            if (value.domain == "CloudPhotoLibraryErrorDomain" && value.code == 1005)
                || (value.domain == NSCocoaErrorDomain && value.code == NSFileWriteOutOfSpaceError)
                || (value.domain == NSPOSIXErrorDomain && value.code == 28) { return true }
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    static func message(at directory: URL) -> String {
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: directory.path)
        let bytes = (attributes?[.systemFreeSize] as? NSNumber)?.int64Value
        let space = bytes.map { " (\(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)) available)" } ?? ""
        return "Downloads paused: disk nearly full\(space). Free up disk space; retrying automatically every 30 seconds."
    }

    static func run<Value>(at directory: URL, retryDelay: TimeInterval = 30,
                           check: () throws -> Void,
                           blocked: (String?) -> Void,
                           wait: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                           operation: () throws -> Value) throws -> Value {
        var waiting = false
        defer { if waiting { blocked(nil) } }
        while true {
            try check()
            do { return try operation() }
            catch {
                try check()
                guard isOutOfSpace(error) else { throw error }
                waiting = true
                blocked(message(at: directory))
                // Stop remains responsive while waiting. Retain the same item
                // and its place in the bounded preparation window for retry.
                var remaining = max(0, retryDelay)
                while remaining > 0 {
                    try check()
                    let interval = min(0.2, remaining)
                    wait(interval); remaining -= interval
                }
            }
        }
    }
}
