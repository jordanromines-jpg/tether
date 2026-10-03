import Foundation
import IOKit.pwr_mgt

/// Wakes the display when someone connects and keeps it awake while connected.
final class PowerManager {
    private var displayAssertion: IOPMAssertionID = 0
    private var held = false

    func wake() {
        var id: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("Tether client connected" as CFString, kIOPMUserActiveLocal, &id)
    }

    func setKeepAwake(_ on: Bool) {
        if on, !held {
            held = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Tether session active" as CFString, &displayAssertion) == kIOReturnSuccess
        } else if !on, held {
            IOPMAssertionRelease(displayAssertion)
            held = false
        }
    }
}
