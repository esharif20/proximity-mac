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

    private static func randomEvent(_ g: inout Gen, idle: inout Double, dt: Double) -> Event {
        switch Int.random(in: 0..<20, using: &g) {
        case 0..<7:
            idle = Bool.random(using: &g) && Int.random(in: 0..<4, using: &g) == 0 ? 0 : idle + dt
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
            var t = 0.0, idle = 0.0
            for _ in 0..<400 {
                let dt = Double.random(in: 0.1...5, using: &g)
                t += dt
                let event = Self.randomEvent(&g, idle: &idle, dt: dt)
                let effects = engine.handle(event, at: t)
                if engine.state == .present && idle < s.idleBeforeCheck {
                    let costly = effects.filter { $0 == .sample(.checking) || $0 == .sample(.watching) || $0 == .listen(true) }
                    #expect(costly.isEmpty, "seed \(seed) t \(t) \(event) -> \(effects)")
                }
            }
        }
    }

    @Test func effectsAreEmittedOnlyOnChange() {
        for seed in UInt64(1000)..<1300 {
            var g = Gen(seed: seed)
            var engine = PresenceEngine(settings: Self.randomSettings(&g))
            var t = 0.0, idle = 0.0
            var sampling = SamplingMode.off, listening = false, grace = false, dark = false
            for _ in 0..<400 {
                let dt = Double.random(in: 0.1...5, using: &g)
                t += dt
                for e in engine.handle(Self.randomEvent(&g, idle: &idle, dt: dt), at: t) {
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
