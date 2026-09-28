import Foundation

/// Storage and offline failures pause requests; they must not discard an album.
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

    static func isOffline(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        for _ in 0..<12 {
            guard let value = current else { break }
            if value.domain == NSURLErrorDomain && [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost].contains(value.code) { return true }
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    static func userMessage(_ error: Error) -> String {
        if isOffline(error) { return "iCloud could not download this item because the internet connection is unavailable. Check your connection and retry the album; prepared items can still play." }
        if isOutOfSpace(error) { return "There is not enough disk space to prepare this item. Free some space and retry." }
        let value = error as NSError
        if value.domain == NSURLErrorDomain && value.code == NSURLErrorTimedOut {
            return "iCloud took too long to respond. Check your connection, try opening this item in Photos, then retry the album."
        }
        if value.domain == "PHPhotosErrorDomain" {
            return "Photos could not provide this item (error \(value.code)). Try opening it in Photos to finish downloading, then retry the album."
        }
        return String(value.localizedDescription.prefix(600))
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
                guard isOutOfSpace(error) || isOffline(error) else { throw error }
                waiting = true
                blocked(isOffline(error) ? "iCloud downloads paused: internet connection unavailable. Check your connection; retrying automatically every \(Int(retryDelay)) seconds. Prepared items can still play." : message(at: directory))
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
