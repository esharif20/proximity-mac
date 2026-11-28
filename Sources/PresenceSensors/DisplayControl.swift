import CoreGraphics
import Foundation
import IOKit.pwr_mgt
import Synchronization

/// Turns the displays off and on and locks the session. Screens Off only: the Mac stays awake.
///
/// With `keepBuiltInOn` (ADR 0005) Screens Off only darkens the external displays with a zero gamma
/// table, and macOS never sleeps a display, so there is no password on return. Without it, every
/// display sleeps through `pmset displaysleepnow` as before.
///
/// A crash cannot leave a monitor dark: macOS restores every gamma table when the process exits.
public final class DisplayControl: DisplayControlling {
    /// The hardware actions, as closures so tests can check the wiring without darkening the screen.
    struct Actions: Sendable {
        var sleepDisplays: @Sendable () -> Void
        var declareUserActivity: @Sendable () -> Void
        var lockSession: @Sendable () -> Void
        var darkenExternals: @Sendable () -> Void = {}
        var restoreGamma: @Sendable () -> Void = {}
    }

    private struct State {
        var keepBuiltInOn = true
        /// External gamma is at zero right now, so every way out has something to restore.
        var externalsDark = false
    }

    private let actions: Actions
    private let state = Mutex(State())

    public convenience init() {
        self.init(actions: .system)
    }

    init(actions: Actions) {
        self.actions = actions
    }

    public var keepBuiltInOn: Bool {
        get { state.withLock { $0.keepBuiltInOn } }
        set {
            let wasDark = state.withLock { state -> Bool in
                state.keepBuiltInOn = newValue
                defer { if !newValue { state.externalsDark = false } }
                return state.externalsDark
            }
            // Turning the mode off while dark must not strand the monitors at zero gamma.
            if !newValue, wasDark { actions.restoreGamma() }
        }
    }

    /// Whether the external displays are darkened right now.
    public var externalsDark: Bool { state.withLock { $0.externalsDark } }

    public func screensOff() {
        let keep = state.withLock { state -> Bool in
            if state.keepBuiltInOn { state.externalsDark = true }
            return state.keepBuiltInOn
        }
        if keep { actions.darkenExternals() } else { actions.sleepDisplays() }
    }

    public func screensOn() {
        restore()
        actions.declareUserActivity()
    }

    public func lock() { actions.lockSession() }

    /// Puts every display's gamma back. Safe to call at any time; it does nothing unless dark.
    public func restore() {
        let wasDark = state.withLock { state -> Bool in
            defer { state.externalsDark = false }
            return state.externalsDark
        }
        if wasDark { actions.restoreGamma() }
    }

    /// A display was plugged in or out. While dark, a new external gets the zero table too.
    public func displaysChanged() {
        if externalsDark { actions.darkenExternals() }
    }

    /// The displays to darken: every display outside the built-in's mirror set, since a mirror
    /// shares the built-in's picture and darkening it would hide the Away screen.
    static func externals(_ displays: [DisplayInfo]) -> [CGDirectDisplayID] {
        displays.filter { !showsBuiltIn($0.id, in: displays) }.map(\.id)
    }

    /// Whether the display shows the built-in panel's picture: it is the built-in, or it is in a
    /// mirror set with it. In mirror mode `NSScreen` reports only the set's primary, which may be
    /// the external, so the app asks this rather than `CGDisplayIsBuiltin`.
    static func showsBuiltIn(_ id: CGDirectDisplayID, in displays: [DisplayInfo]) -> Bool {
        // Displays in one mirror set all mirror the same primary; the primary mirrors nothing.
        func set(_ display: DisplayInfo) -> CGDirectDisplayID {
            display.mirrors == kCGNullDirectDisplay ? display.id : display.mirrors
        }
        guard let display = displays.first(where: { $0.id == id }) else { return false }
        return displays.contains { $0.isBuiltIn && set($0) == set(display) }
    }

    /// `showsBuiltIn` against the displays online now.
    public static func showsBuiltIn(_ id: CGDirectDisplayID) -> Bool {
        showsBuiltIn(id, in: onlineDisplays())
    }

    static func onlineDisplays() -> [DisplayInfo] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { id in
            DisplayInfo(id: id, isBuiltIn: CGDisplayIsBuiltin(id) != 0, mirrors: CGDisplayMirrorsDisplay(id))
        }
    }

    struct DisplayInfo: Equatable {
        var id: CGDirectDisplayID
        var isBuiltIn: Bool
        /// `kCGNullDirectDisplay` when not mirroring.
        var mirrors: CGDirectDisplayID = kCGNullDirectDisplay
    }
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
            _ = lockScreenFunction?()
        },
        darkenExternals: {
            for id in DisplayControl.externals(DisplayControl.onlineDisplays()) {
                // A transfer formula with max 0 maps every level to black. OLED pixels at 0 are unlit.
                CGSetDisplayTransferByFormula(id, 0, 0, 1, 0, 0, 1, 0, 0, 1)
            }
        },
        restoreGamma: {
            CGDisplayRestoreColorSyncSettings()
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
