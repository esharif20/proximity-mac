import Foundation
import Observation
// Scoped imports: the contract's `Observation` struct would shadow the Observation module the
// `@Observable` macro expands into.
import enum PresenceCore.Command
import enum PresenceCore.CommandParser
import struct PresenceCore.PresenceEngine
import enum PresenceCore.Effect
import enum PresenceCore.Event
import enum PresenceCore.PresenceState
import enum PresenceCore.SamplingMode
import struct PresenceCore.Settings
import struct PresenceCore.TraceLine

/// Runs the engine: feeds it idle time, ticks and observations, and executes the effects it returns.
/// No presence or timing rule lives here; the engine decides and this class only acts.
@MainActor @Observable
final class Coordinator {

    // Every write to an observed property redraws the menu bar item, so each one is written only
    // when its value changes. That keeps the active mode near zero CPU.
    private(set) var state: PresenceState
    /// Monotonic seconds for the countdowns on screen. It moves only while a Grace countdown or a
    /// timed Hold is showing; the rest of the time nothing on screen depends on it.
    private(set) var now: Double
    /// When the Grace countdown ends, while it is showing.
    private(set) var graceUntil: Double?
    private(set) var listening = false
    /// The latest distance the camera reported, for the live readout in Settings.
    private(set) var lastDistanceCm: Double?
    private(set) var isCalibrating = false
    /// The last Command recognised, shown in the menu. The transcript itself is never kept.
    private(set) var lastCommand: Command?
    let bench: BenchMode?
    /// The menu bar glyph. It redraws itself only when what it shows changes.
    @ObservationIgnored let icon = MenuBarIcon()

    var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            store.save(settings)
            engine.update(settings: settings)
            seams.camera.calibration = settings.calibration
        }
    }

    var isEnabled: Bool {
        get { state != .off }
        set {
            guard bench == nil, newValue != isEnabled else { return }
            store.enabled = newValue
            send(newValue ? .enable : .disable)
        }
    }

    @ObservationIgnored private var engine: PresenceEngine
    @ObservationIgnored private let seams: Seams
    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let overlay = GraceOverlay()
    @ObservationIgnored private let keepAwake = KeepAwake()
    @ObservationIgnored private let log: FeatureLog
    /// The rate the engine last asked for; a Settings preview may raise it but never replaces it.
    @ObservationIgnored private var engineMode: SamplingMode = .off
    @ObservationIgnored private var previewing = false
    @ObservationIgnored private var micBusy: Bool?
    /// The engine's clock, updated on every event without redrawing anything.
    @ObservationIgnored private var clock: Double
    /// Mirrors the stored setting so the per-event check doesn't read UserDefaults.
    @ObservationIgnored private var logging: Bool

    var isLogging: Bool {
        get { access(keyPath: \.isLogging); return logging }
        set {
            withMutation(keyPath: \.isLogging) {
                store.featureLog = newValue
                logging = newValue
            }
            if !newValue { log.close() }
        }
    }

    /// The Trigger word as spoken at the start of a Command, for on-screen hints.
    var triggerPhrase: String {
        let word = settings.triggerWord.trimmingCharacters(in: .whitespaces)
        return word.isEmpty ? "Screen" : word.prefix(1).uppercased() + word.dropFirst()
    }

    init(seams: Seams = .live, store: SettingsStore = SettingsStore(), bench: BenchMode? = BenchMode(arguments: CommandLine.arguments)) {
        let settings = store.load()
        var seams = seams
        if bench == .reading { seams.idle = GrowingIdle() }
        self.seams = seams
        self.store = store
        self.bench = bench
        self.settings = settings
        self.engine = PresenceEngine(settings: settings)
        self.log = FeatureLog()
        seams.camera.calibration = settings.calibration
        self.state = .off
        let start = ProcessInfo.processInfo.systemUptime
        self.now = start
        self.clock = start
        self.logging = store.featureLog

        seams.camera.onObservation { [weak self] observation in
            let observation = bench?.rewrite(observation) ?? observation
            Task { @MainActor in
                if let distance = observation.distanceCm { self?.lastDistanceCm = distance }
                self?.send(.observation(observation))
            }
        }
        seams.voice.onTranscript { [weak self] transcript in
            Task { @MainActor in self?.heard(transcript) }
        }
        startTimer()

        if let bench, bench.pinsEngine {
            state = bench.state
            keepAwake.set(true)
            bench.effects.forEach(perform)
            refreshIcon()
        } else if bench == .reading || store.enabled {
            send(.enable)
        }
    }

    func send(_ event: Event) {
        clock = ProcessInfo.processInfo.systemUptime
        guard bench?.pinsEngine != true else { return }
        if logging { log.append(TraceLine(t: clock, event: event)) }
        let effects = engine.handle(event, at: clock)
        if engine.state != state {
            state = engine.state
            keepAwake.set(state != .off)
            refreshIcon()
        }
        effects.forEach(perform)
        if showsCountdown || graceUntil != nil { now = clock }
    }

    /// Marks the moment the person thought a decision was wrong, so the trace can be checked later.
    func markWrong() {
        log.markWrong(at: ProcessInfo.processInfo.systemUptime)
    }

    /// While Settings is open the camera samples so the distance readout is live.
    func setPreviewing(_ on: Bool) {
        previewing = on
        if !on { lastDistanceCm = nil }
        applySampling()
    }

    func calibrate() async {
        guard !isCalibrating else { return }
        isCalibrating = true
        defer { isCalibrating = false }
        if let calibration = await seams.camera.calibrate() {
            settings.calibration = calibration
        }
    }

    private func refreshIcon() {
        icon.show(state, listening: listening, graceSeconds: settings.graceSeconds)
    }

    private func heard(_ transcript: String) {
        guard let command = CommandParser.parse(transcript, triggerWord: settings.triggerWord) else { return }
        lastCommand = command
        send(.command(command))
    }

    private func applySampling() {
        seams.camera.setMode(previewing && engineMode == .off ? .checking : engineMode)
    }

    private func startTimer() {
        // One coalesced timer: while input is recent this read is the only work the app does.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private var showsCountdown: Bool {
        switch state {
        case .grace, .hold(until: .some): true
        default: false
        }
    }

    private func tick() {
        let idle = seams.idle.secondsSinceInput()
        send(.idle(seconds: idle))
        // The mic only matters when the engine could ask to listen, so skip the CoreAudio query
        // while the person is typing. Only changes go to the engine, so a call starting is one event.
        if mightListen(idle: idle) {
            let busy = seams.mic.micInUseByOtherApp()
            if busy != micBusy {
                micBusy = busy
                send(.micBusy(busy))
            }
        }
        send(.tick)
    }

    private func mightListen(idle: Double) -> Bool {
        guard settings.voiceEnabled else { return false }
        switch state {
        case .grace, .away, .hold: return true
        case .off: return false
        case .present, .checking: return idle >= settings.listenAfterIdle
        }
    }

    private func perform(_ effect: Effect) {
        switch effect {
        case .screensOff: seams.display.screensOff()
        case .screensOn: seams.display.screensOn()
        case .lock: seams.display.lock()
        case .sample(let mode):
            engineMode = mode
            applySampling()
        case .listen(let on):
            guard on != listening else { return }
            listening = on
            refreshIcon()
            on ? seams.voice.start() : seams.voice.stop()
        case .showGrace(let seconds):
            now = clock
            graceUntil = clock + Double(seconds)
            if !overlay.isShowing { overlay.show(GraceNotice(coordinator: self)) }
        case .hideGrace:
            guard graceUntil != nil else { return }
            graceUntil = nil
            overlay.hide()
        }
    }
}
