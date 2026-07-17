import Foundation
import IOKit.pwr_mgt

/// Holds an IOKit power assertion that prevents the display from sleeping while a Display
/// session is connected (D2), so the spare Mac's screen doesn't sleep mid-stream. Create and
/// release are balanced through the `assertionID` optional — never leaks: `acquire` while already
/// held is a no-op, and `deinit` releases any outstanding assertion.
final class PowerAssertion {
    private var assertionID: IOPMAssertionID?

    /// Take the no-display-sleep assertion if not already held.
    func acquire(reason: String) {
        guard assertionID == nil else { return }
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id)
        if result == kIOReturnSuccess {
            assertionID = id
            Log.event(.display, "power assertion acquired (no display sleep)")
        } else {
            Log.event(.display, "power assertion failed (\(result))", level: .error)
        }
    }

    /// Release the assertion if held. Idempotent.
    func release() {
        guard let id = assertionID else { return }
        IOPMAssertionRelease(id)
        assertionID = nil
        Log.event(.display, "power assertion released")
    }

    deinit { release() }
}
