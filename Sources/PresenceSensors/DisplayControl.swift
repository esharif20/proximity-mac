import Foundation
import IOKit.pwr_mgt

/// Turns every display off and on and locks the session. Screens Off only: the Mac stays awake.
public final class DisplayControl: DisplayControlling {
    /// The three hardware actions, as closures so tests can check the wiring without darkening the screen.
    struct Actions: Sendable {
        var sleepDisplays: @Sendable () -> Void
        var declareUserActivity: @Sendable () -> Void
        var lockSession: @Sendable () -> Void
    }

    private let actions: Actions

    public convenience init() {
        self.init(actions: .system)
    }

    init(actions: Actions) {
        self.actions = actions
    }

    public func screensOff() { actions.sleepDisplays() }
    public func screensOn() { actions.declareUserActivity() }
    public func lock() { actions.lockSession() }
}

extension DisplayControl.Actions {
    static let system = DisplayControl.Actions(
        sleepDisplays: {
            // `pmset displaysleepnow` darkens every display, docked externals included, and never
            // triggers System Sleep. It needs no privileges.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["displaysleepnow"]
            try? process.run()
        },
        declareUserActivity: {
            // Declaring user activity is the supported way to wake displays without synthesising input.
            var assertion = IOPMAssertionID(0)
            let result = IOPMAssertionDeclareUserActivity(
                "Proximity Mac presence" as CFString, kIOPMUserActiveLocal, &assertion)
            if result == kIOReturnSuccess { IOPMAssertionRelease(assertion) }
        },
        lockSession: {
            lockScreenFunction?()
        }
    )

    /// `SACLockScreenImmediate` from login.framework is what the menu bar "Lock Screen" item calls.
    /// It is private, so it is looked up at runtime and lock does nothing if it is missing.
    private static let lockScreenFunction: (@convention(c) () -> Int32)? = {
        let path = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
        guard let handle = dlopen(path, RTLD_LAZY), let symbol = dlsym(handle, "SACLockScreenImmediate") else {
            return nil
        }
        return unsafeBitCast(symbol, to: (@convention(c) () -> Int32).self)
    }()
}
