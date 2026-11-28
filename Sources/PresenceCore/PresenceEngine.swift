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
    /// When the last keyboard or mouse input happened, from the latest idle reading.
    private var lastInputAt: Double?
    private var micBusy = false
    /// When the current check started; a check that finds nobody close for `absenceBeforeAway` leads to grace.
    private var checkStarted: Double = 0
    /// After a close sighting the camera rests until this time.
    private var recheckNotBefore: Double = -.infinity
    /// Set by "go to sleep" said at the desk: a close face must not undo it until the person has left once.
    private var sleptAtDesk = false
    /// When the current Away began; watching stops `stopWatchingAfterMinutes` later (overnight, say).
    private var awayStarted: Double = 0
    /// When the camera last recognised the Owner, in any state. Nil until it has.
    private var ownerSeenAt: Double?

    /// The latest Command dropped because the Owner was not seen recently, so the app can say why.
    /// Cleared by the next accepted Command.
    public private(set) var lastIgnoredCommand: Command?

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
                if case .idle(let seconds) = event { _ = recordIdle(seconds, at: now) }
                if case .micBusy(let busy) = event { micBusy = busy }
                if case .observation(let o) = event { noteOwner(o, at: now) }
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
            if recordIdle(seconds, at: now) { userIsBack(now, &out) }
            if state == .present, seconds >= settings.idleBeforeCheck, now >= recheckNotBefore {
                startChecking(now, &out)
            }
        case .observation(let o):
            noteOwner(o, at: now)
            guard o.person && (o.distanceCm ?? 0) <= settings.deskRadiusCm else {
                sleptAtDesk = false
                return
            }
            if state == .away && sleptAtDesk { return }
            // Only waking from Away is gated: before Away any close person counts, so a mismatch
            // can never be what turns the screens off.
            if state == .away && settings.onlyWakeForMe && o.owner != true { return }
            switch state {
            case .checking, .grace, .away, .hold(until: nil):
                backAtDesk(now, &out)
                recheckNotBefore = now + settings.recheckAfterSeen
            default:
                break
            }
        case .command(let command) where !acceptsCommand(at: now):
            lastIgnoredCommand = command
            if state == .away {
                // Someone spoke, so the camera looks again (even past the cutoff) and the Owner's face
                // can make the next Command count.
                awayStarted = now
                setSampling(.watching, &out)
            }
        case .command(.sleep):
            lastIgnoredCommand = nil
            goAway(now, &out)
            sleptAtDesk = true
        case .command(.wake):
            lastIgnoredCommand = nil
            switch settings.wakeUpMode {
            case .untilSleepOrDesk: startHold(until: nil, &out)
            case .timedHold: startHold(until: now + Double(settings.wakeUpHoldMinutes) * 60, &out)
            }
        case .command(.hold(let minutes)):
            lastIgnoredCommand = nil
            startHold(until: now + Double(minutes) * 60, &out)
        case .micBusy(let busy):
            micBusy = busy
        case .tick, .enable, .disable:
            break
        }
    }

    private mutating func noteOwner(_ o: Observation, at now: Double) {
        if o.owner == true { ownerSeenAt = now }
    }

    /// With "Voice needs me" on, a Command counts only from someone recently recognised as the Owner,
    /// so a voice from across the room cannot drive the screens.
    private func acceptsCommand(at now: Double) -> Bool {
        guard settings.voiceNeedsMe else { return true }
        guard let seen = ownerSeenAt else { return false }
        return now - seen <= settings.voiceAfterSeenMinutes * 60
    }

    /// Stores the reading and says whether it shows new input. Comparing input times rather than
    /// idle values catches a keypress between two small readings; the margin absorbs timer jitter.
    private mutating func recordIdle(_ seconds: Double, at now: Double) -> Bool {
        let inputAt = now - seconds
        let isNew = lastInputAt.map { inputAt > $0 + 0.05 } ?? false
        if isNew || lastInputAt == nil { lastInputAt = inputAt }
        lastIdle = seconds
        return isNew
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

    private mutating func goAway(_ now: Double, _ out: inout [Effect]) {
        // "Go to sleep" said while already Away must not restart the timer and turn watching back on.
        if state == .away { return }
        awayStarted = now
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
            goAway(now, &out)
        case .away where now - awayStarted >= settings.stopWatchingAfterMinutes * 60:
            // Long gone: stop paying for the camera. Input, "wake up" and "keep it on" still wake.
            setSampling(.off, &out)
        case .hold(let until?) where now >= until:
            // Someone typing when the hold runs out is at the desk; checking now would time absence too early.
            if lastIdle < settings.idleBeforeCheck { backAtDesk(now, &out) } else { startChecking(now, &out) }
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
        case .grace, .away, .hold(until: nil):
            wanted = true
        case .hold:
            // A timed hold keeps the screens on for someone who may be typing; listen only once they stop.
            wanted = lastIdle >= settings.listenAfterIdle
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
