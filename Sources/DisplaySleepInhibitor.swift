import Foundation
import IOKit.pwr_mgt

/// Keeps the display awake only while slideshow playback is active.
/// Power assertions leave the user's Energy settings unchanged.
final class DisplaySleepInhibitor {
    private let lock = NSLock()
    private var assertionID: IOPMAssertionID?

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return assertionID != nil
    }

    func setPlaybackActive(_ active: Bool) {
        lock.lock()
        defer { lock.unlock() }

        if active {
            guard assertionID == nil else { return }
            var identifier: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Spatial Slideshow playback" as CFString,
                &identifier
            )
            if result == kIOReturnSuccess { assertionID = identifier }
        } else if let identifier = assertionID {
            if IOPMAssertionRelease(identifier) == kIOReturnSuccess {
                assertionID = nil
            }
        }
    }

    deinit {
        if let identifier = assertionID { IOPMAssertionRelease(identifier) }
    }
}
