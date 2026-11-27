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
    @Test func eachCallRunsOnlyItsOwnAction() {
        let calls = Mutex<[String]>([])
        let control = DisplayControl(actions: .init(
            sleepDisplays: { calls.withLock { $0.append("off") } },
            declareUserActivity: { calls.withLock { $0.append("on") } },
            lockSession: { calls.withLock { $0.append("lock") } }
        ))
        control.screensOff()
        control.screensOn()
        control.lock()
        #expect(calls.withLock { $0 } == ["off", "on", "lock"])
    }

    @Test func publicInitIsUsableThroughTheSeam() {
        let control: any DisplayControlling = DisplayControl()
        _ = control
    }
}
