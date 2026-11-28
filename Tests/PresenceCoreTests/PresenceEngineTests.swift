import Foundation
import PresenceCore
import Testing

private let close = Event.observation(Observation(source: .camera, person: true, distanceCm: 60))
private let far = Event.observation(Observation(source: .camera, person: true, distanceCm: 300))
private let nobody = Event.observation(Observation(source: .camera, person: false))

/// Drives an engine through timed events and keeps the effects of the last step.
private struct Driver {
    var engine: PresenceEngine
    init(_ settings: Settings = Settings(), enabled: Bool = true) {
        engine = PresenceEngine(settings: settings)
        if enabled { _ = engine.handle(.enable, at: 0) }
    }
    @discardableResult mutating func at(_ t: Double, _ e: Event) -> [Effect] { engine.handle(e, at: t) }
    var state: PresenceState { engine.state }

    /// Idle from t=0 until checking starts at t=30.
    mutating func toChecking() {
        at(10, .idle(seconds: 10))
        at(30, .idle(seconds: 30))
    }
    /// Checking from 30, nobody seen, grace at 60.
    mutating func toGrace() {
        toChecking()
        at(45, nobody)
        at(60, nobody)
    }
    /// Grace from 60 for 10 s, Away at 70.
    mutating func toAway() {
        toGrace()
        at(70, .tick)
    }
}

@Suite struct PresenceEngineTests {
    @Test func startsOffAndEnables() {
        var d = Driver(enabled: false)
        #expect(d.state == .off)
        #expect(d.at(0, .idle(seconds: 100)) == [])
        d.at(1, .enable)
        #expect(d.state == .present)
    }

    @Test func checksOnceIdleLongEnough() {
        var d = Driver()
        #expect(d.at(29, .idle(seconds: 29)) == [])
        #expect(d.at(30, .idle(seconds: 30)) == [.sample(.checking), .listen(true)])
        #expect(d.state == .checking)
        #expect(d.at(31, .idle(seconds: 31)) == [])
        #expect(d.at(32, .tick) == [])
    }

    @Test func closePersonWhileCheckingIsPresentAndRestsTheCamera() {
        var d = Driver()
        d.toChecking()
        #expect(d.at(31, close) == [.sample(.off)])
        #expect(d.state == .present)
        #expect(d.at(60, .idle(seconds: 60)) == [])
        #expect(d.at(91, .idle(seconds: 91)) == [.sample(.checking)])
    }

    @Test func farOrNoPersonForAbsenceLeadsToGrace() {
        var d = Driver()
        d.toChecking()
        #expect(d.at(40, far) == [])
        #expect(d.at(59, nobody) == [])
        #expect(d.at(60, .tick) == [.showGrace(seconds: 10)])
        #expect(d.state == .grace(until: 70))
    }

    @Test func graceDeadlineGoesAway() {
        var d = Driver()
        d.toGrace()
        #expect(d.at(70, .tick) == [.hideGrace, .screensOff, .sample(.watching)])
        #expect(d.state == .away)
    }

    @Test func awayLocksOnlyWhenAsked() {
        var s = Settings()
        s.lockWhenAway = true
        var d = Driver(s)
        d.toGrace()
        #expect(d.at(70, .tick) == [.hideGrace, .screensOff, .lock, .sample(.watching)])
    }

    @Test func inputClosePersonOrCommandCancelsGrace() {
        var a = Driver(); a.toGrace()
        #expect(a.at(62, .idle(seconds: 0)) == [.hideGrace, .sample(.off), .listen(false)])
        #expect(a.state == .present)

        var b = Driver(); b.toGrace()
        #expect(b.at(62, close).first == .hideGrace)
        #expect(b.state == .present)

        var c = Driver(); c.toGrace()
        #expect(c.at(62, .command(.hold(minutes: 5))).first == .hideGrace)
        #expect(c.state == .hold(until: 362))

        var e = Driver(); e.toGrace()
        _ = e.at(62, .command(.sleep))
        #expect(e.state == .away)
    }

    @Test func inputOrClosePersonWakesFromAway() {
        var a = Driver(); a.toAway()
        #expect(a.at(80, .idle(seconds: 0)) == [.screensOn, .sample(.off), .listen(false)])
        #expect(a.state == .present)

        var b = Driver(); b.toAway()
        #expect(b.at(80, close).prefix(2) == [.screensOn, .sample(.off)])
        #expect(b.state == .present)
    }

    @Test func farPersonDoesNotWake() {
        var d = Driver(); d.toAway()
        #expect(d.at(80, far) == [])
        #expect(d.state == .away)
    }

    @Test func sleepCommandGoesAwayFromPresent() {
        var d = Driver()
        #expect(d.at(5, .command(.sleep)) == [.screensOff, .sample(.watching), .listen(true)])
        #expect(d.state == .away)
    }

    @Test func wakeHoldsUntilSleepOrDesk() {
        var d = Driver(); d.toAway()
        #expect(d.at(100, .command(.wake)).prefix(1) == [.screensOn])
        #expect(d.state == .hold(until: nil))
        #expect(d.at(10_000, .tick) == [])
        d.at(10_001, close)
        #expect(d.state == .present)

        var e = Driver(); e.toAway()
        e.at(100, .command(.wake))
        e.at(200, .command(.sleep))
        #expect(e.state == .away)
    }

    @Test func wakeCanBeATimedHold() {
        var s = Settings()
        s.wakeUpMode = .timedHold
        s.wakeUpHoldMinutes = 2
        var d = Driver(s); d.toAway()
        d.at(100, .command(.wake))
        #expect(d.state == .hold(until: 220))
    }

    @Test func timedHoldEndsInChecking() {
        var d = Driver(); d.toAway()
        d.at(100, .command(.hold(minutes: 1)))
        #expect(d.state == .hold(until: 160))
        #expect(d.at(159, .tick) == [])
        #expect(d.at(160, .tick).contains(.sample(.checking)))
        #expect(d.state == .checking)
    }

    @Test func disableUndoesEverything() {
        var d = Driver(); d.toAway()
        #expect(d.at(80, .disable) == [.sample(.off), .listen(false), .screensOn])
        #expect(d.state == .off)
        var g = Driver(); g.toGrace()
        #expect(g.at(61, .disable) == [.sample(.off), .listen(false), .hideGrace])
        var p = Driver()
        #expect(p.at(1, .disable) == [])
    }

    @Test func micBusyStopsListening() {
        var d = Driver(); d.toAway()
        #expect(d.at(80, .micBusy(true)) == [.listen(false)])
        #expect(d.at(81, .tick) == [])
        #expect(d.at(82, .micBusy(false)) == [.listen(true)])
    }

    @Test func voiceDisabledNeverListens() {
        var s = Settings()
        s.voiceEnabled = false
        var d = Driver(s); d.toAway()
        #expect(!d.at(80, .command(.wake)).contains(.listen(true)))
    }

    // MARK: - Properties over random event sequences

    private static func randomSettings(_ g: inout Gen) -> Settings {
        var s = Settings()
        s.idleBeforeCheck = .random(in: 1...60, using: &g)
        s.absenceBeforeAway = .random(in: 1...60, using: &g)
        s.graceSeconds = .random(in: 0...15, using: &g)
        s.recheckAfterSeen = .random(in: 0...120, using: &g)
        s.listenAfterIdle = .random(in: 0...60, using: &g)
        s.voiceEnabled = .random(using: &g)
        s.lockWhenAway = .random(using: &g)
        s.wakeUpMode = Bool.random(using: &g) ? .timedHold : .untilSleepOrDesk
        s.wakeUpHoldMinutes = .random(in: 1...5, using: &g)
        return s
    }

    /// `input` is set when the event is an idle reading that shows a keypress since the last reading.
    private static func randomEvent(_ g: inout Gen, idle: inout Double, dt: Double, input: inout Bool) -> Event {
        input = false
        switch Int.random(in: 0..<20, using: &g) {
        case 0..<7:
            if Int.random(in: 0..<8, using: &g) == 0 {
                // A keypress somewhere since the last reading, so the new reading need not be below the old one.
                idle = Double.random(in: 0...(dt - 0.06), using: &g)
                input = true
            } else {
                idle += dt
            }
            return .idle(seconds: idle)
        case 7..<12:
            return .observation(Observation(source: .camera, person: .random(using: &g),
                                            distanceCm: Bool.random(using: &g) ? .random(in: 20...400, using: &g) : nil))
        case 12..<15: return .tick
        case 15: return .command([.wake, .sleep, .hold(minutes: .random(in: 1...3, using: &g))].randomElement(using: &g)!)
        case 16: return .micBusy(.random(using: &g))
        case 17: return Int.random(in: 0..<5, using: &g) == 0 ? .disable : .tick
        default: return .enable
        }
    }

    @Test func resourceRuleNoSensingWhilePresentAndActive() {
        for seed in UInt64(0)..<300 {
            var g = Gen(seed: seed)
            let s = Self.randomSettings(&g)
            var engine = PresenceEngine(settings: s)
            var t = 0.0, idle = 0.0, input = false
            for _ in 0..<400 {
                let dt = Double.random(in: 0.1...5, using: &g)
                t += dt
                let event = Self.randomEvent(&g, idle: &idle, dt: dt, input: &input)
                let effects = engine.handle(event, at: t)
                if engine.state == .present && idle < s.idleBeforeCheck {
                    let costly = effects.filter { $0 == .sample(.checking) || $0 == .sample(.watching) || $0 == .listen(true) }
                    #expect(costly.isEmpty, "seed \(seed) t \(t) \(event) -> \(effects)")
                }
            }
        }
    }

    @Test func inputInAnyStateLeavesCameraAndMicOff() {
        for seed in UInt64(2000)..<2300 {
            var g = Gen(seed: seed)
            let s = Self.randomSettings(&g)
            var engine = PresenceEngine(settings: s)
            var t = 0.0, idle = 0.0, input = false
            var sampling = SamplingMode.off, listening = false
            for _ in 0..<400 {
                let dt = Double.random(in: 0.1...5, using: &g)
                t += dt
                let before = engine.state
                let event = Self.randomEvent(&g, idle: &idle, dt: dt, input: &input)
                for e in engine.handle(event, at: t) {
                    if case .sample(let m) = e { sampling = m }
                    if case .listen(let on) = e { listening = on }
                }
                // Recent input, below both thresholds: whatever the state was, the person is at the keyboard.
                if input && idle < s.idleBeforeCheck && idle < s.listenAfterIdle {
                    #expect(sampling == .off && !listening, "seed \(seed) t \(t) from \(before) to \(engine.state)")
                }
            }
        }
    }

    @Test func effectsAreEmittedOnlyOnChange() {
        for seed in UInt64(1000)..<1300 {
            var g = Gen(seed: seed)
            let s = Self.randomSettings(&g)
            var engine = PresenceEngine(settings: s)
            var t = 0.0, idle = 0.0, input = false
            var sampling = SamplingMode.off, listening = false, grace = false, dark = false
            for _ in 0..<400 {
                let dt = Double.random(in: 0.1...5, using: &g)
                t += dt
                for e in engine.handle(Self.randomEvent(&g, idle: &idle, dt: dt, input: &input), at: t) {
                    switch e {
                    case .sample(let m): #expect(m != sampling, "seed \(seed)"); sampling = m
                    case .listen(let on): #expect(on != listening, "seed \(seed)"); listening = on
                    case .showGrace: #expect(!grace, "seed \(seed)"); grace = true
                    case .hideGrace: #expect(grace, "seed \(seed)"); grace = false
                    case .screensOff: #expect(!dark, "seed \(seed)"); dark = true
                    case .screensOn: #expect(dark, "seed \(seed)"); dark = false
                    case .lock: #expect(dark, "seed \(seed)")
                    }
                }
                if engine.state == .off {
                    #expect(sampling == .off && !listening && !grace && !dark, "seed \(seed)")
                }
            }
        }
    }
}

@Suite struct PresenceEngineLateEvidenceTests {
    @Test func inputJustAfterGraceDeadlineNeverFlashesScreensOff() {
        var e = PresenceEngine(settings: Settings())
        _ = e.handle(.enable, at: 0)
        _ = e.handle(.idle(seconds: 30), at: 30)
        _ = e.handle(.tick, at: 60)
        #expect(e.handle(.idle(seconds: 0), at: 71) == [.hideGrace, .sample(.off), .listen(false)])
        #expect(e.state == .present)
    }
}

@Suite struct PresenceEngineSleepCommandTests {
    private let close = Event.observation(Observation(source: .camera, person: true, distanceCm: 60))

    private func sleptAtDesk() -> PresenceEngine {
        var e = PresenceEngine(settings: Settings())
        _ = e.handle(.enable, at: 0)
        _ = e.handle(.idle(seconds: 4), at: 4)
        _ = e.handle(.command(.sleep), at: 5)
        return e
    }

    @Test func closeFaceDoesNotUndoSleepUntilThePersonHasLeft() {
        var e = sleptAtDesk()
        #expect(e.handle(close, at: 6) == [])
        #expect(e.state == .away)
        _ = e.handle(.observation(Observation(source: .camera, person: false)), at: 8)
        #expect(e.handle(close, at: 20).prefix(2) == [.screensOn, .sample(.off)])
        #expect(e.state == .present)
    }

    @Test func farSightingCountsAsLeft() {
        var e = sleptAtDesk()
        _ = e.handle(.observation(Observation(source: .camera, person: true, distanceCm: 300)), at: 8)
        _ = e.handle(close, at: 20)
        #expect(e.state == .present)
    }

    @Test func inputAndWakeAlwaysWake() {
        var a = sleptAtDesk()
        #expect(a.handle(.idle(seconds: 0), at: 6).first == .screensOn)
        #expect(a.state == .present)
        var b = sleptAtDesk()
        #expect(b.handle(.command(.wake), at: 6).first == .screensOn)
        #expect(b.state == .hold(until: nil))
    }

    @Test func automaticAwayStillWakesOnACloseFace() {
        var e = sleptAtDesk()
        _ = e.handle(.idle(seconds: 0), at: 6)
        _ = e.handle(.idle(seconds: 30), at: 36)
        _ = e.handle(.tick, at: 66)
        _ = e.handle(.tick, at: 76)
        #expect(e.state == .away)
        #expect(e.handle(close, at: 80).first == .screensOn)
    }
}

/// The three sequences from the GH-2 review, kept as regressions.
@Suite struct PresenceEngineReviewTests {
    @Test func inputDuringATimedHoldStopsListening() {
        var e = PresenceEngine(settings: Settings())
        _ = e.handle(.enable, at: 0)
        _ = e.handle(.idle(seconds: 40), at: 40)
        #expect(!e.handle(.command(.hold(minutes: 10)), at: 41).contains(.listen(false)))
        #expect(e.handle(.idle(seconds: 0.2), at: 42) == [.listen(false)])
        #expect(e.state == .hold(until: 641))
    }

    @Test func timedHoldDeadlineWithRecentInputIsPresent() {
        var e = PresenceEngine(settings: Settings())
        _ = e.handle(.enable, at: 0)
        _ = e.handle(.idle(seconds: 1), at: 1)
        _ = e.handle(.command(.hold(minutes: 1)), at: 1)
        _ = e.handle(.idle(seconds: 0.3), at: 60)
        #expect(e.handle(.idle(seconds: 0.2), at: 61) == [])
        #expect(e.state == .present)
        #expect(e.handle(.idle(seconds: 30.2), at: 91) == [.sample(.checking), .listen(true)])
    }

    @Test func timedHoldDeadlineWhileIdleChecks() {
        var e = PresenceEngine(settings: Settings())
        _ = e.handle(.enable, at: 0)
        _ = e.handle(.idle(seconds: 40), at: 40)
        _ = e.handle(.command(.hold(minutes: 1)), at: 40)
        #expect(e.handle(.tick, at: 100).contains(.sample(.checking)))
        #expect(e.state == .checking)
    }

    @Test func keypressAfterSleepWakesEvenWhenIdleReadsHigher() {
        var e = PresenceEngine(settings: Settings())
        _ = e.handle(.enable, at: 0)
        _ = e.handle(.idle(seconds: 0.1), at: 10)
        _ = e.handle(.command(.sleep), at: 10.3)
        #expect(e.handle(.idle(seconds: 0.4), at: 11) == [.screensOn, .sample(.off), .listen(false)])
        #expect(e.state == .present)
    }

    @Test func steadyIdleReadingsAreNotInput() {
        var e = PresenceEngine(settings: Settings())
        _ = e.handle(.enable, at: 0)
        _ = e.handle(.idle(seconds: 5), at: 5)
        _ = e.handle(.command(.sleep), at: 6)
        #expect(e.handle(.idle(seconds: 7.02), at: 7) == [])
        #expect(e.state == .away)
    }
}

@Suite struct PresenceEngineStopWatchingTests {
    /// Away at 70 with the default 15-minute cutoff, so watching stops at 970.
    private func awayWithCameraOff() -> Driver {
        var d = Driver()
        d.toAway()
        return d
    }

    @Test func watchingStopsAfterTheCutoffAndStaysAway() {
        var d = Driver()
        d.toAway()
        #expect(d.at(969, .tick).isEmpty)
        #expect(d.at(970, .tick) == [.sample(.off)])
        #expect(d.state == .away)
        #expect(d.at(2000, .tick).isEmpty)
        // No observations arrive with the camera off, but a stray one must not wake for a far person.
        #expect(d.at(2001, far).isEmpty)
    }

    @Test func inputWakeAndHoldStillWakeAfterTheCutoff() {
        var a = awayWithCameraOff()
        a.at(970, .tick)
        let input = a.at(1000, .idle(seconds: 0.5))
        #expect(input.contains(.screensOn))
        #expect(a.state == .present)

        var b = awayWithCameraOff()
        b.at(970, .tick)
        #expect(b.at(1000, .command(.wake)).contains(.screensOn))

        var c = awayWithCameraOff()
        c.at(970, .tick)
        #expect(c.at(1000, .command(.hold(minutes: 5))).contains(.screensOn))
        #expect(c.state == .hold(until: 1300))
    }

    @Test func reEnteringAwayRestartsTheTimer() {
        var d = Driver()
        d.toAway()
        d.at(970, .tick)
        // Back at 1000, then idle again: checking at 1030, grace at 1060, Away at 1070.
        d.at(1000, .idle(seconds: 0))
        d.at(1030, .idle(seconds: 30))
        d.at(1045, nobody)
        d.at(1060, nobody)
        #expect(d.at(1070, .tick).contains(.sample(.watching)))
        #expect(d.state == .away)
        #expect(d.at(1969, .tick).isEmpty)
        #expect(d.at(1970, .tick) == [.sample(.off)])
    }

    @Test func sleepCommandWhileAwayDoesNotRestartWatching() {
        var d = Driver()
        d.toAway()
        d.at(970, .tick)
        #expect(!d.at(1000, .command(.sleep)).contains(.sample(.watching)))
    }

    @Test func aShorterSettingAppliesToTheCurrentAway() {
        var d = Driver()
        d.toAway()
        var s = Settings()
        s.stopWatchingAfterMinutes = 1
        d.engine.update(settings: s)
        #expect(d.at(130, .tick) == [.sample(.off)])
    }

    @Test func listeningKeepsItsRulesAfterTheCutoff() {
        var d = Driver()
        d.toAway()
        let off = d.at(970, .tick)
        #expect(!off.contains(.listen(false)))
        #expect(d.at(1000, .micBusy(true)) == [.listen(false)])
        #expect(d.at(1010, .micBusy(false)) == [.listen(true)])
    }

    /// The resource rule, extended: once an Away passes its cutoff, no watching until the state leaves Away.
    @Test func noWatchingAfterTheCutoffUntilAwayEnds() {
        var reached = 0
        for seed in UInt64(5000)..<5300 {
            var g = Gen(seed: seed)
            var s = Settings()
            s.idleBeforeCheck = .random(in: 1...20, using: &g)
            s.absenceBeforeAway = .random(in: 1...20, using: &g)
            s.graceSeconds = .random(in: 0...10, using: &g)
            s.recheckAfterSeen = .random(in: 0...60, using: &g)
            s.stopWatchingAfterMinutes = .random(in: 0.05...2, using: &g)
            var engine = PresenceEngine(settings: s)
            _ = engine.handle(.enable, at: 0)
            var t = 0.0, idle = 0.0
            var awaySince: Double?
            var sampling = SamplingMode.off
            var reachedCutoff = false
            for _ in 0..<600 {
                let dt = Double.random(in: 0.1...5, using: &g)
                t += dt
                let event: Event
                switch Int.random(in: 0..<30, using: &g) {
                case 0: idle = 0; event = .idle(seconds: 0)
                case 1: event = .command(.wake)
                case 2: event = .command(.sleep)
                case 3..<12: idle += dt; event = .idle(seconds: idle)
                case 12..<18: event = Bool.random(using: &g) ? nobody : far
                case 18: event = close
                default: event = .tick
                }
                let wasAway = engine.state == .away
                let effects = engine.handle(event, at: t)
                for case .sample(let m) in effects { sampling = m }
                if engine.state == .away {
                    if !wasAway { awaySince = t }
                    if wasAway, let since = awaySince, t - since >= s.stopWatchingAfterMinutes * 60 {
                        reachedCutoff = true
                        #expect(sampling == .off, "seed \(seed) t \(t) \(event)")
                        #expect(!effects.contains(.sample(.watching)), "seed \(seed) t \(t) \(event)")
                    }
                } else {
                    awaySince = nil
                }
            }
            reached += reachedCutoff ? 1 : 0
        }
        #expect(reached > 20, "the random runs must actually reach the cutoff: \(reached)")
    }
}

private func closeFace(owner: Bool?) -> Event {
    .observation(Observation(source: .camera, person: true, distanceCm: 60, owner: owner))
}

@Suite struct PresenceEngineOwnerTests {
    private func onlyMe() -> Settings {
        var s = Settings()
        s.onlyWakeForMe = true
        return s
    }

    private func voiceNeedsMe() -> Settings {
        var s = Settings()
        s.voiceNeedsMe = true
        return s
    }

    @Test(arguments: [false, nil] as [Bool?])
    func onlyWakeForMeKeepsAwayForSomeoneElse(owner: Bool?) {
        var d = Driver(onlyMe())
        d.toAway()
        #expect(d.at(80, closeFace(owner: owner)) == [])
        #expect(d.state == .away)
    }

    @Test func onlyWakeForMeWakesForTheOwner() {
        var d = Driver(onlyMe())
        d.toAway()
        #expect(d.at(80, closeFace(owner: true)).contains(.screensOn))
        #expect(d.state == .present)
    }

    @Test func onlyWakeForMeStillWakesOnInput() {
        var d = Driver(onlyMe())
        d.toAway()
        #expect(d.at(80, .idle(seconds: 0)).contains(.screensOn))
        #expect(d.state == .present)
    }

    @Test func anyCloseFaceStillCountsBeforeAway() {
        // A mismatch must never lead to Screens Off, so checking and grace treat everyone alike.
        var d = Driver(onlyMe())
        d.toChecking()
        d.at(31, closeFace(owner: false))
        #expect(d.state == .present)

        var g = Driver(onlyMe())
        g.toGrace()
        #expect(g.at(62, closeFace(owner: false)).contains(.hideGrace))
        #expect(g.state == .present)

        var h = Driver(onlyMe())
        h.at(5, .command(.wake))
        #expect(h.state == .hold(until: nil))
        h.at(10, closeFace(owner: false))
        #expect(h.state == .present)
    }

    @Test func voiceNeedsMeIgnoresCommandsWhenTheOwnerWasNeverSeen() {
        var d = Driver(voiceNeedsMe())
        #expect(d.at(5, .command(.sleep)) == [])
        #expect(d.state == .present)
        #expect(d.engine.lastIgnoredCommand == .sleep)
    }

    @Test func voiceNeedsMeAcceptsCommandsSoonAfterTheOwnerWasSeen() {
        var d = Driver(voiceNeedsMe())
        d.at(5, .command(.sleep))
        d.at(10, closeFace(owner: true))
        #expect(d.at(10 + 29 * 60, .command(.sleep)).contains(.screensOff))
        #expect(d.state == .away)
        #expect(d.engine.lastIgnoredCommand == nil)
    }

    @Test func voiceNeedsMeIgnoresCommandsLongAfterTheOwnerWasSeen() {
        var d = Driver(voiceNeedsMe())
        d.at(10, closeFace(owner: true))
        #expect(d.at(10 + 31 * 60, .command(.hold(minutes: 5))) == [])
        #expect(d.engine.lastIgnoredCommand == .hold(minutes: 5))
    }

    @Test func ownerSeenWhileAwayCountsForVoice() {
        var s = voiceNeedsMe()
        s.onlyWakeForMe = true
        var d = Driver(s)
        d.toAway()
        d.at(80, closeFace(owner: true))
        d.at(85, .idle(seconds: 90))
        #expect(d.at(90, .command(.sleep)).contains(.screensOff))
    }

    @Test func ignoredCommandAfterTheCutoffWatchesAgainForTheOwner() {
        var s = voiceNeedsMe()
        s.onlyWakeForMe = true
        var d = Driver(s)
        d.toAway()
        #expect(d.at(1000, .tick) == [.sample(.off)])
        // The Owner said a Command but has not been seen: the camera must look so the next one can count.
        #expect(d.at(1010, .command(.wake)) == [.sample(.watching)])
        #expect(d.state == .away)
        #expect(d.engine.lastIgnoredCommand == .wake)
        #expect(d.at(1010 + 899, .tick) == [], "the cutoff restarts from the ignored Command")
        #expect(d.at(1010 + 900, .tick) == [.sample(.off)])
    }

    @Test func ignoredCommandWhileWatchingRestartsTheCutoff() {
        var d = Driver(voiceNeedsMe())
        d.toAway()
        #expect(d.at(500, .command(.sleep)) == [])
        #expect(d.at(970, .tick) == [])
        #expect(d.at(1400, .tick) == [.sample(.off)])
    }

    @Test func ignoredCommandOutsideAwayChangesNothing() {
        var d = Driver(voiceNeedsMe())
        d.toChecking()
        #expect(d.at(31, .command(.hold(minutes: 5))) == [])
        #expect(d.state == .checking)
    }

    @Test func commandsWorkWithoutVoiceNeedsMe() {
        var d = Driver()
        #expect(d.at(5, .command(.sleep)).contains(.screensOff))
        #expect(d.engine.lastIgnoredCommand == nil)
    }

    @Test func noObservationOfSomeoneElseEverWakesFromAway() {
        var checked = 0
        for seed in UInt64(5000)..<5300 {
            var g = Gen(seed: seed)
            var s = Settings()
            s.onlyWakeForMe = true
            s.voiceNeedsMe = .random(using: &g)
            s.graceSeconds = .random(in: 0...15, using: &g)
            s.absenceBeforeAway = .random(in: 1...60, using: &g)
            var engine = PresenceEngine(settings: s)
            _ = engine.handle(.enable, at: 0)
            var t = 0.0, idle = 0.0
            for _ in 0..<400 {
                let dt = Double.random(in: 0.1...5, using: &g)
                t += dt
                let event: Event
                switch Int.random(in: 0..<10, using: &g) {
                case 0..<4: idle += dt; event = .idle(seconds: idle)
                case 4..<8:
                    event = .observation(Observation(
                        source: .camera, person: .random(using: &g),
                        distanceCm: .random(in: 20...400, using: &g),
                        owner: Bool.random(using: &g) ? false : nil))
                case 8: event = .command(.sleep)
                default: event = .tick
                }
                let wasAway = engine.state == .away
                let effects = engine.handle(event, at: t)
                if wasAway, case .observation = event {
                    checked += 1
                    #expect(!effects.contains(.screensOn), "seed \(seed) t \(t) \(event)")
                    #expect(engine.state == .away, "seed \(seed) t \(t) \(event)")
                }
            }
        }
        #expect(checked > 1000, "the random runs must actually see faces while Away: \(checked)")
    }
}

private let motion = Event.observation(Observation(source: .camera, person: false, motion: true))

@Suite struct PresenceEngineMotionTests {
    @Test func motionDuringGraceChecksAgainWithAFreshTimer() {
        var d = Driver()
        d.toGrace()
        #expect(d.at(62, motion) == [.hideGrace])
        #expect(d.state == .checking)
        #expect(d.engine.reason == .checking)
        #expect(d.at(91, nobody) == [])
        #expect(d.at(92, .tick) == [.showGrace(seconds: 10)])
    }

    @Test func motionWhileCheckingDoesNotRestartTheTimer() {
        var d = Driver()
        d.toChecking()
        d.at(50, motion)
        #expect(d.at(60, .tick) == [.showGrace(seconds: 10)])
    }

    @Test func theFourthGraceRunsOutDespiteMotion() {
        var d = Driver()
        d.toChecking()
        var off: Double?
        for t in stride(from: 32.0, through: 400, by: 2) where off == nil {
            if d.at(t, motion).contains(.screensOff) { off = t }
        }
        // Graces at 60, 92, 124 are undone at 62, 94, 126; the one at 156 runs out at 166.
        #expect(off == 166)
        #expect(d.state == .away)
    }

    @Test func aCloseSightingResetsTheMotionCount() {
        var d = Driver()
        d.toChecking()
        var t = 32.0
        func run(until end: Double) -> Bool {
            var wentOff = false
            while t <= end {
                if d.at(t, motion).contains(.screensOff) { wentOff = true }
                t += 2
            }
            return wentOff
        }
        #expect(!run(until: 150))
        d.at(151, close)
        #expect(d.state == .present)
        // Rests 60 s, checks 30 s, then three more graces can be undone.
        d.at(211, .idle(seconds: 211))
        #expect(d.state == .checking)
        t = 212
        #expect(!run(until: 330))
    }

    @Test func inputResetsTheMotionCount() {
        var d = Driver()
        d.toChecking()
        for t in stride(from: 32.0, through: 150, by: 2) { d.at(t, motion) }
        d.at(151, .idle(seconds: 0))
        #expect(d.state == .present)
        d.at(181, .idle(seconds: 30))
        #expect(d.state == .checking)
        var wentOff = false
        for t in stride(from: 182.0, through: 300, by: 2) where d.at(t, motion).contains(.screensOff) { wentOff = true }
        #expect(!wentOff)
    }

    @Test func motionWhileAwayDoesNotWake() {
        var d = Driver()
        d.toAway()
        #expect(d.at(72, motion) == [])
        #expect(d.state == .away)
    }
}

@Suite struct PresenceEngineReasonTests {
    @Test func reasonFollowsEachTransition() {
        var d = Driver(enabled: false)
        #expect(d.engine.reason == .turnedOff)
        d.at(0, .enable)
        #expect(d.engine.reason == .typing)
        d.toChecking()
        #expect(d.engine.reason == .checking)
        d.at(60, nobody)
        #expect(d.engine.reason == .nobodySeen)
        d.at(70, .tick)
        #expect(d.engine.reason == .nobodySeen)
        d.at(71, close)
        #expect(d.engine.reason == .seenClose)
        d.at(72, .command(.sleep))
        #expect(d.engine.reason == .sleepCommand)
        d.at(73, .command(.wake))
        #expect(d.engine.reason == .command)
        d.at(74, .command(.hold(minutes: 5)))
        #expect(d.engine.reason == .holdCommand)
        d.at(75, .idle(seconds: 0))
        #expect(d.engine.reason == .holdCommand)
        d.at(76, .disable)
        #expect(d.engine.reason == .turnedOff)
    }

    @Test func reasonNamesTheOwnerAndTyping() {
        var d = Driver()
        d.toAway()
        d.at(71, .observation(Observation(source: .camera, person: true, distanceCm: 60, owner: true)))
        #expect(d.engine.reason == .ownerSeen)
        d.at(200, .idle(seconds: 100))
        d.at(230, nobody)
        d.at(231, .idle(seconds: 0))
        #expect(d.engine.reason == .typing)
    }

    @Test func reasonSaysWhenWatchingStopped() {
        var d = Driver()
        d.toAway()
        d.at(70 + 15 * 60, .tick)
        #expect(d.engine.reason == .stoppedWatching)
    }

    @Test func aTimedHoldEndingWhileIdleChecks() {
        var d = Driver()
        d.at(10, .idle(seconds: 40))
        d.at(11, .command(.hold(minutes: 1)))
        d.at(71, .idle(seconds: 101))
        #expect(d.state == .checking)
        #expect(d.engine.reason == .checking)
    }
}
