import Foundation

/// Decides every Screens Off. Pure: events and times in, effects out, so traces replay exactly.
public struct PresenceEngine {
    public private(set) var state: PresenceState = .off
    private var settings: Settings

    // What the outside world is currently doing, so each effect is emitted only when it changes.
    private var sampling: SamplingMode = .off
    private var listening = false
    private var graceShown = false
    private var screensDark = false

    private var lastIdle: Double = 0
    private var micBusy = false
    /// When the current check started; a check that finds nobody close for `absenceBeforeAway` leads to grace.
    private var checkStarted: Double = 0
    /// After a close sighting the camera rests until this time.
    private var recheckNotBefore: Double = -.infinity
    /// Set by "go to sleep" said at the desk: a close face must not undo it until the person has left once.
    private var sleptAtDesk = false

    public init(settings: Settings) {
        self.settings = settings
    }

    public mutating func update(settings: Settings) {
        self.settings = settings
    }

    public mutating func handle(_ event: Event, at now: Double) -> [Effect] {
        var out: [Effect] = []
        switch event {
        case .enable:
            if state == .off { state = .present }
        case .disable:
            disable(&out)
            return out
        default:
            guard state != .off else {
                // Facts still count while off, so enabling later starts from the real idle time.
                if case .idle(let seconds) = event { lastIdle = seconds }
                if case .micBusy(let busy) = event { micBusy = busy }
                return []
            }
            // Evidence first: input or a close sighting that arrives just after a deadline still wins,
            // so the screens never flash off and straight back on.
            react(to: event, at: now, &out)
            advanceDeadlines(now, &out)
        }
        updateListening(&out)
        return out
    }

    // MARK: - Transitions

    private mutating func react(to event: Event, at now: Double, _ out: inout [Effect]) {
        switch event {
        case .idle(let seconds):
            let input = seconds < lastIdle
            lastIdle = seconds
            if input { userIsBack(now, &out) }
            if state == .present, seconds >= settings.idleBeforeCheck, now >= recheckNotBefore {
                startChecking(now, &out)
            }
        case .observation(let o):
            guard o.person && (o.distanceCm ?? 0) <= settings.deskRadiusCm else {
                sleptAtDesk = false
                return
            }
            if state == .away && sleptAtDesk { return }
            switch state {
            case .checking, .grace, .away, .hold(until: nil):
                backAtDesk(now, &out)
                recheckNotBefore = now + settings.recheckAfterSeen
            default:
                break
            }
        case .command(.sleep):
            goAway(&out)
            sleptAtDesk = true
        case .command(.wake):
            switch settings.wakeUpMode {
            case .untilSleepOrDesk: startHold(until: nil, &out)
            case .timedHold: startHold(until: now + Double(settings.wakeUpHoldMinutes) * 60, &out)
            }
        case .command(.hold(let minutes)):
            startHold(until: now + Double(minutes) * 60, &out)
        case .micBusy(let busy):
            micBusy = busy
        case .tick, .enable, .disable:
            break
        }
    }

    /// Input means someone is at the keyboard.
    private mutating func userIsBack(_ now: Double, _ out: inout [Effect]) {
        recheckNotBefore = -.infinity
        switch state {
        case .checking, .grace, .away, .hold(until: nil):
            backAtDesk(now, &out)
        default:
            break
        }
    }

    private mutating func backAtDesk(_ now: Double, _ out: inout [Effect]) {
        state = .present
        setGrace(false, &out)
        setScreensDark(false, &out)
        setSampling(.off, &out)
    }

    private mutating func startChecking(_ now: Double, _ out: inout [Effect]) {
        state = .checking
        checkStarted = now
        setSampling(.checking, &out)
    }

    private mutating func goAway(_ out: inout [Effect]) {
        state = .away
        sleptAtDesk = false
        setGrace(false, &out)
        if !screensDark {
            screensDark = true
            out.append(.screensOff)
            if settings.lockWhenAway { out.append(.lock) }
        }
        setSampling(.watching, &out)
    }

    private mutating func startHold(until deadline: Double?, _ out: inout [Effect]) {
        state = .hold(until: deadline)
        setGrace(false, &out)
        setScreensDark(false, &out)
        // An open-ended hold ends when the person is seen back at the desk, so the camera keeps watching.
        setSampling(deadline == nil ? .watching : .off, &out)
    }

    private mutating func advanceDeadlines(_ now: Double, _ out: inout [Effect]) {
        switch state {
        case .checking where now - checkStarted >= settings.absenceBeforeAway:
            state = .grace(until: now + Double(settings.graceSeconds))
            setGrace(true, &out)
        case .grace(let until) where now >= until:
            goAway(&out)
        case .hold(let until?) where now >= until:
            startChecking(now, &out)
        default:
            break
        }
    }

    private mutating func disable(_ out: inout [Effect]) {
        state = .off
        setSampling(.off, &out)
        setListening(false, &out)
        setGrace(false, &out)
        setScreensDark(false, &out)
    }

    // MARK: - Effects, emitted only on change

    private mutating func updateListening(_ out: inout [Effect]) {
        let wanted: Bool
        switch state {
        case .off:
            wanted = false
        case .present:
            // The resource rule: an active person at the desk never pays for the microphone.
            wanted = lastIdle >= settings.listenAfterIdle && lastIdle >= settings.idleBeforeCheck
        case .checking:
            wanted = lastIdle >= settings.listenAfterIdle
        case .grace, .away, .hold:
            wanted = true
        }
        setListening(wanted && settings.voiceEnabled && !micBusy, &out)
    }

    private mutating func setSampling(_ mode: SamplingMode, _ out: inout [Effect]) {
        guard sampling != mode else { return }
        sampling = mode
        out.append(.sample(mode))
    }

    private mutating func setListening(_ on: Bool, _ out: inout [Effect]) {
        guard listening != on else { return }
        listening = on
        out.append(.listen(on))
    }

    private mutating func setGrace(_ shown: Bool, _ out: inout [Effect]) {
        guard graceShown != shown else { return }
        graceShown = shown
        out.append(shown ? .showGrace(seconds: settings.graceSeconds) : .hideGrace)
    }

    private mutating func setScreensDark(_ dark: Bool, _ out: inout [Effect]) {
        guard screensDark != dark else { return }
        screensDark = dark
        out.append(dark ? .screensOff : .screensOn)
    }
}
