import Foundation
import Observation
// Scoped imports: the contract's `Observation` struct would shadow the Observation module the
// `@Observable` macro expands into.
import enum PresenceCore.Command
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
    typealias Engine = StandInEngine
    typealias Parser = StandInParser

    private(set) var state: PresenceState
    /// Monotonic seconds at the last tick, so countdowns in the UI refresh once a second.
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

    @ObservationIgnored private var engine: Engine
    @ObservationIgnored private let seams: Seams
    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let overlay = GraceOverlay()
    @ObservationIgnored private let log: FeatureLog
    /// The rate the engine last asked for; a Settings preview may raise it but never replaces it.
    @ObservationIgnored private var engineMode: SamplingMode = .off
    @ObservationIgnored private var previewing = false
    @ObservationIgnored private var micBusy: Bool?

    var isLogging: Bool {
        get { access(keyPath: \.isLogging); return store.featureLog }
        set {
            withMutation(keyPath: \.isLogging) { store.featureLog = newValue }
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
        self.seams = seams
        self.store = store
        self.bench = bench
        self.settings = settings
        self.engine = Engine(settings: settings)
        self.log = FeatureLog()
        seams.camera.calibration = settings.calibration
        self.state = .off
        self.now = ProcessInfo.processInfo.systemUptime

        seams.camera.onObservation { [weak self] observation in
            Task { @MainActor in
                if let distance = observation.distanceCm { self?.lastDistanceCm = distance }
                self?.send(.observation(observation))
            }
        }
        seams.voice.onTranscript { [weak self] transcript in
            Task { @MainActor in self?.heard(transcript) }
        }
        startTimer()

        if let bench {
            state = bench.state
            bench.effects.forEach(perform)
        } else if store.enabled {
            send(.enable)
        }
    }

    func send(_ event: Event) {
        now = ProcessInfo.processInfo.systemUptime
        guard bench == nil else { return }
        if isLogging { log.append(TraceLine(t: now, event: event)) }
        let effects = engine.handle(event, at: now)
        state = engine.state
        effects.forEach(perform)
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

    private func heard(_ transcript: String) {
        guard let command = Parser.parse(transcript, triggerWord: settings.triggerWord) else { return }
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

    private func tick() {
        send(.idle(seconds: seams.idle.secondsSinceInput()))
        // Only changes go to the engine, so the trace stays small and a call starting is one event.
        let busy = seams.mic.micInUseByOtherApp()
        if busy != micBusy {
            micBusy = busy
            send(.micBusy(busy))
        }
        send(.tick)
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
            on ? seams.voice.start() : seams.voice.stop()
        case .showGrace(let seconds):
            graceUntil = now + Double(seconds)
            if !overlay.isShowing { overlay.show(GraceNotice(coordinator: self)) }
        case .hideGrace:
            graceUntil = nil
            overlay.hide()
        }
    }
}
