import AppKit
import IOKit.pwr_mgt

/// Keeps the Mac out of idle System Sleep while Proximity Mac is on, so overnight jobs keep running
/// with the screens off. Displays may still sleep; only the system is held awake.
@MainActor
final class KeepAwake {
    private var assertion: IOPMAssertionID?
    private var quitObserver: (any NSObjectProtocol)?

    init() {
        quitObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.set(false) }
        }
    }

    var isHeld: Bool { assertion != nil }

    func set(_ on: Bool) {
        if on, assertion == nil {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Proximity Mac keeps the Mac awake" as CFString,
                &id
            )
            if result == kIOReturnSuccess { assertion = id }
        } else if !on, let id = assertion {
            IOPMAssertionRelease(id)
            assertion = nil
        }
    }
}
