import Synchronization
import Testing
@testable import PresenceSensors

@Test func sensorsSeeTheContract() {
    #expect(SamplingMode.off.rawValue == "off")
}

@Suite struct IdleSourceTests {
    @Test func readsAFiniteNonNegativeIdleTime() {
        let seconds = IdleSource().secondsSinceInput()
        #expect(seconds.isFinite)
        #expect(seconds >= 0)
    }

    @Test(arguments: [(UInt64(0), 0.0), (1_500_000_000, 1.5), (90_000_000_000, 90.0)])
    func convertsNanosecondsToSeconds(ns: UInt64, seconds: Double) {
        #expect(IdleSource.seconds(fromNanoseconds: ns) == seconds)
    }

    @Test func isCheapEnoughToPollEverySecond() {
        let source = IdleSource()
        let clock = ContinuousClock()
        let elapsed = clock.measure { for _ in 0..<100 { _ = source.secondsSinceInput() } }
        // 100 reads well under a second means one read a second is negligible.
        #expect(elapsed < .milliseconds(500))
    }
}

@Suite struct DisplayControlTests {
    /// Records which hardware action ran, so no test touches a real display.
    final class Calls: Sendable {
        private let list = Mutex<[String]>([])
        func withLock<R>(_ body: (inout [String]) -> R) -> R { list.withLock { body(&$0) } }
    }

    private static func recording(_ calls: Calls) -> DisplayControl.Actions {
        .init(
            sleepDisplays: { calls.withLock { $0.append("sleep") } },
            declareUserActivity: { calls.withLock { $0.append("wake") } },
            lockSession: { calls.withLock { $0.append("lock") } },
            darkenExternals: { calls.withLock { $0.append("darken") } },
            restoreGamma: { calls.withLock { $0.append("restore") } }
        )
    }

    @Test func keepsBuiltInOnByDefault() {
        let calls = Calls()
        let control = DisplayControl(actions: Self.recording(calls))
        #expect(control.keepBuiltInOn)
        control.screensOff()
        #expect(control.externalsDark)
        control.screensOn()
        #expect(!control.externalsDark)
        #expect(calls.withLock { $0 } == ["darken", "restore", "wake"])
    }

    @Test func withoutKeepBuiltInOnSleepsEveryDisplay() {
        let calls = Calls()
        let control = DisplayControl(actions: Self.recording(calls))
        control.keepBuiltInOn = false
        control.screensOff()
        control.screensOn()
        control.lock()
        #expect(!control.externalsDark)
        #expect(calls.withLock { $0 } == ["sleep", "wake", "lock"])
    }

    @Test func turningTheModeOffWhileDarkRestores() {
        let calls = Calls()
        let control = DisplayControl(actions: Self.recording(calls))
        control.screensOff()
        control.keepBuiltInOn = false
        #expect(!control.externalsDark)
        #expect(calls.withLock { $0 } == ["darken", "restore"])
    }

    @Test func restoreOnlyActsWhenDark() {
        let calls = Calls()
        let control = DisplayControl(actions: Self.recording(calls))
        control.restore()
        control.displaysChanged()
        #expect(calls.withLock { $0 }.isEmpty)
        control.screensOff()
        control.displaysChanged()
        control.restore()
        control.restore()
        #expect(calls.withLock { $0 } == ["darken", "darken", "restore"])
    }

    @Test func darkensOnlyExternalsNotMirroringTheBuiltIn() {
        typealias Info = DisplayControl.DisplayInfo
        #expect(DisplayControl.externals([Info(id: 1, isBuiltIn: true), Info(id: 2, isBuiltIn: false),
                                          Info(id: 3, isBuiltIn: false)]) == [2, 3])
        // Clamshell: no built-in, so every display goes dark.
        #expect(DisplayControl.externals([Info(id: 2, isBuiltIn: false)]) == [2])
        // An external mirroring the built-in shows the Away screen too.
        #expect(DisplayControl.externals([Info(id: 1, isBuiltIn: true), Info(id: 2, isBuiltIn: false, mirrors: 1)]) == [])
        #expect(DisplayControl.externals([Info(id: 1, isBuiltIn: true, mirrors: 2), Info(id: 2, isBuiltIn: false)]) == [])
        // Two externals mirroring each other are both external.
        #expect(DisplayControl.externals([Info(id: 1, isBuiltIn: true), Info(id: 2, isBuiltIn: false),
                                          Info(id: 3, isBuiltIn: false, mirrors: 2)]) == [2, 3])
    }

    @Test func publicInitIsUsableThroughTheSeam() {
        let control: any DisplayControlling = DisplayControl()
        _ = control
    }
}
