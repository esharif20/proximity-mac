import Foundation
import Testing
@testable import PresenceSensors

@Suite struct MediaUsageTests {
    static let own: pid_t = 100, player: pid_t = 200, tool: pid_t = 300
    static func regular(_ pid: pid_t) -> Bool { pid != tool }
    static func held(_ byProcess: [pid_t: [[String: Any]]]) -> Bool {
        MediaUsage.displayHeldByOtherApp(byProcess, ownPID: own, isRegularApp: regular)
    }
    static func assertion(_ type: String, level: Int? = nil) -> [String: Any] {
        var a: [String: Any] = ["AssertType": type, "AssertName": "test"]
        if let level { a["AssertLevel"] = NSNumber(value: level) }
        return a
    }

    @Test func aPlayerHoldingTheDisplayCounts() {
        #expect(Self.held([Self.player: [Self.assertion("PreventUserIdleDisplaySleep", level: 255)]]))
        #expect(Self.held([Self.player: [Self.assertion("NoDisplaySleepAssertion")]]))
    }

    @Test func ourOwnAssertionDoesNotCount() {
        #expect(!Self.held([Self.own: [Self.assertion("PreventUserIdleDisplaySleep")]]))
    }

    @Test func aCommandLineToolDoesNotCount() {
        #expect(!Self.held([Self.tool: [Self.assertion("PreventUserIdleDisplaySleep")]]))
    }

    @Test func systemSleepAssertionsDoNotCount() {
        #expect(!Self.held([Self.player: [Self.assertion("PreventUserIdleSystemSleep"), Self.assertion("PreventSystemSleep")]]))
    }

    @Test func aReleasedAssertionDoesNotCount() {
        #expect(!Self.held([Self.player: [Self.assertion("PreventUserIdleDisplaySleep", level: 0)]]))
    }

    @Test func malformedEntriesAreSkipped() {
        #expect(!Self.held([Self.player: [["AssertType": 5], [:]]]))
        #expect(!Self.held([:]))
    }

    @Test func anyMatchingProcessAmongOthersCounts() {
        #expect(Self.held([
            Self.own: [Self.assertion("PreventUserIdleDisplaySleep")],
            Self.tool: [Self.assertion("PreventUserIdleDisplaySleep")],
            Self.player: [Self.assertion("PreventUserIdleSystemSleep"), Self.assertion("PreventUserIdleDisplaySleep")],
        ]))
    }

    @Test func theLiveReadingDoesNotCrash() {
        _ = MediaUsage().mediaPlaying()
    }
}
