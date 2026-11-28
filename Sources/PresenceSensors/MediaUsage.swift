import AppKit
import Foundation
import IOKit.pwr_mgt

/// Tells whether another app is keeping the display awake (a film, a presentation), so the screens stay on.
public struct MediaUsage: MediaReading {
    public init() {}

    public func mediaPlaying() -> Bool {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess, let dict = raw?.takeRetainedValue() else {
            return false
        }
        var byProcess: [pid_t: [[String: Any]]] = [:]
        for (key, value) in dict as NSDictionary {
            guard let pid = (key as? NSNumber)?.int32Value, let list = value as? [[String: Any]] else { continue }
            byProcess[pid] = list
        }
        return Self.displayHeldByOtherApp(byProcess, ownPID: getpid(), isRegularApp: Self.isRegularApp)
    }

    /// Assertion types a player or a presentation takes to stop the display from sleeping.
    static let displayTypes: Set<String> = ["PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion"]

    /// `byProcess` is the shape `IOPMCopyAssertionsByProcess` returns. Only regular apps count, so a
    /// command-line `caffeinate -d` or a background daemon does not hold the screens on.
    static func displayHeldByOtherApp(
        _ byProcess: [pid_t: [[String: Any]]], ownPID: pid_t, isRegularApp: (pid_t) -> Bool
    ) -> Bool {
        byProcess.contains { pid, assertions in
            pid != ownPID && assertions.contains(where: holdsDisplay) && isRegularApp(pid)
        }
    }

    private static func holdsDisplay(_ assertion: [String: Any]) -> Bool {
        guard let type = assertion[kIOPMAssertionTypeKey] as? String, displayTypes.contains(type) else { return false }
        // A released assertion can linger in the list with level 0 (off).
        let level = (assertion[kIOPMAssertionLevelKey] as? NSNumber)?.intValue ?? Int(kIOPMAssertionLevelOn)
        return level == Int(kIOPMAssertionLevelOn)
    }

    private static func isRegularApp(_ pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular
    }
}
