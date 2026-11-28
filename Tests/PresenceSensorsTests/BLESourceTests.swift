import Testing
@testable import PresenceSensors

@Suite struct BLESourceTests {
    @Test func theFirstReadingIsReportedAtOnce() {
        var smoother = SignalSmoother()
        #expect(smoother.add(-60, at: 0) == -60)
    }

    @Test func readingsInsideTwoSecondsAreHeldBack() {
        var smoother = SignalSmoother()
        _ = smoother.add(-60, at: 0)
        let held = [0.3, 0.9, 1.5, 1.99].map { smoother.add(-61, at: $0) }
        #expect(held.allSatisfy { $0 == nil })
        #expect(smoother.add(-62, at: 2.0) != nil)
    }

    @Test func aSteadyStreamReportsAboutEveryTwoSeconds() {
        // Adverts arrive about 10 times a second.
        var smoother = SignalSmoother()
        let times = (0..<200).map { Double($0) * 0.1 }
        let reportTimes = times.filter { smoother.add(-55, at: $0) != nil }
        #expect(reportTimes.count == 10)
        let gaps = zip(reportTimes.dropFirst(), reportTimes).map { $0 - $1 }
        #expect(gaps.allSatisfy { abs($0 - 2) < 0.15 })
    }

    @Test func theReportIsTheMedianOfTheLastFive() {
        var smoother = SignalSmoother()
        _ = smoother.add(-90, at: 0)
        for (i, rssi) in [-50.0, -52, -100, -51, -53].enumerated() {
            let report = smoother.add(rssi, at: 0.5 + Double(i) * 0.3)
            if i < 4 { #expect(report == nil) }
        }
        // -90 and then -50 drop out; the -100 dip is ignored.
        #expect(smoother.readings == [-50, -52, -100, -51, -53])
        #expect(smoother.add(-49, at: 2.5) == -52)
    }

    @Test func oneStrayAdvertDoesNotMoveTheSignal() {
        var smoother = SignalSmoother()
        for i in 0..<4 { _ = smoother.add(-60, at: Double(i) * 0.1) }
        #expect(smoother.add(-20, at: 2.0) == -60)
    }

    @Test(arguments: [
        ([-60.0], -60.0),
        ([-60.0, -70], -65.0),
        ([-70.0, -50, -60], -60.0),
        ([-40.0, -80, -60, -50], -55.0),
    ] as [([Double], Double)])
    func median(values: [Double], expected: Double) {
        #expect(SignalSmoother.median(values) == expected)
    }

    @Test func nothingHappensWithoutAnIdentifier() {
        // Off with no identifier never creates the central, so this runs without Bluetooth permission.
        let source = BLESource()
        source.setMode(.checking)
        #expect(source.identifier == nil)
        source.setMode(.off)
    }
}
