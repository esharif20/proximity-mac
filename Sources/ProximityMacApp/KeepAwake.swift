import AppKit
import IOKit.pwr_mgt

/// Keeps the Mac out of idle System Sleep while Proximity Mac is on, so overnight jobs keep running
/// with the screens off. During Monitors Off it also keeps the displays awake: if macOS slept the
/// built-in on its own timer, its lock delay would ask for a password on return.
@MainActor
final class KeepAwake {
    private var system: IOPMAssertionID?
    private var displays: IOPMAssertionID?
    private var quitObserver: (any NSObjectProtocol)?

    init() {
        quitObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.set(false)
                self?.holdDisplays(false)
            }
        }
    }

    var isHeld: Bool { system != nil }
    var holdsDisplays: Bool { displays != nil }

    func set(_ on: Bool) {
        Self.assert(kIOPMAssertPreventUserIdleSystemSleep, "Proximity Mac keeps the Mac awake", on, &system)
    }

    func holdDisplays(_ on: Bool) {
        Self.assert(kIOPMAssertPreventUserIdleDisplaySleep, "Proximity Mac Monitors Off", on, &displays)
    }

    private static func assert(_ type: String, _ name: String, _ on: Bool, _ assertion: inout IOPMAssertionID?) {
        if on, assertion == nil {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), name as CFString, &id)
            if result == kIOReturnSuccess { assertion = id }
        } else if !on, let id = assertion {
            IOPMAssertionRelease(id)
            assertion = nil
        }
    }
}
