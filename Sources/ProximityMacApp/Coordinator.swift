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
import class PresenceSensors.VoiceSource
import struct PresenceSensors.FaceSignature
import struct PresenceSensors.FaceSignatureStore

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
    /// A Face signature is in the Keychain, so the Owner settings can be turned on.
    private(set) var hasFaceSignature = false
    /// Shown briefly in the menu when a Command was ignored because the Owner was not seen.
    private(set) var voiceNeedsFaceNotice = false
    let bench: BenchMode?
    /// The menu bar glyph. It redraws itself only when what it shows changes.
    @ObservationIgnored let icon = MenuBarIcon()

    var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            store.save(settings)
            engine.update(settings: settings)
            seams.camera.calibration = settings.calibration
            if settings.onlyWakeForMe != oldValue.onlyWakeForMe || settings.voiceNeedsMe != oldValue.voiceNeedsMe {
                applyOwner()
            }
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
    @ObservationIgnored private let faceStore = FaceSignatureStore()
    @ObservationIgnored private var faceSignature: FaceSignature?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    /// The rate the engine last asked for; a Settings preview may raise it but never replaces it.
    @ObservationIgnored private var engineMode: SamplingMode = .off
    /// Settings is open, so the camera samples for the live distance readout.
    @ObservationIgnored private var previewing = false
    /// Setup's VisionLab owns the camera, so the presence camera stays off.
    @ObservationIgnored private var labRunning = false
    /// While Setup's voice step shows, transcripts go to it instead of the engine.
    @ObservationIgnored private var setupWords: ((String) -> Void)?
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
        self.faceSignature = faceStore.load()
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
        hasFaceSignature = faceSignature != nil
        applyOwner()
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
        if case .command = event { noteIgnoredCommand() }
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

    /// Setup's VisionLab is using the camera. Only one capture session runs at a time, so the
    /// presence camera turns off until Setup stops.
    func setLabRunning(_ on: Bool) {
        labRunning = on
        applySampling()
    }

    /// Setup's voice step: the microphone listens and the words go to Setup, not the engine, so
    /// trying "wake up" there does not change the state.
    func startSetupVoice(onLevel: @escaping @MainActor (Float) -> Void, onWords: @escaping (String) -> Void) {
        setupWords = onWords
        (seams.voice as? VoiceSource)?.onLevel { level in
            Task { @MainActor in onLevel(level) }
        }
        if !listening { seams.voice.start() }
    }

    func stopSetupVoice() {
        guard setupWords != nil else { return }
        setupWords = nil
        (seams.voice as? VoiceSource)?.onLevel { _ in }
        if !listening { seams.voice.stop() }
    }

    /// Set by the menu bar label, which holds the SwiftUI `openWindow` action.
    @ObservationIgnored var openSetupWindow: (() -> Void)?

    func openSetup() {
        openSetupWindow?()
    }

    /// Keeps a new Face signature in the Keychain. Returns false if the Keychain refused it.
    func saveFaceSignature(_ signature: FaceSignature) -> Bool {
        do {
            try faceStore.save(signature)
        } catch {
            return false
        }
        faceSignature = signature
        hasFaceSignature = true
        applyOwner()
        return true
    }

    /// Removes the Face signature and turns off both Owner settings, which need it.
    func deleteFaceSignature() {
        faceStore.delete()
        faceSignature = nil
        hasFaceSignature = false
        settings.onlyWakeForMe = false
        settings.voiceNeedsMe = false
        applyOwner()
    }

    /// The camera only compares faces when an Owner setting asks for it, so with both off no
    /// embedding is ever computed.
    private func applyOwner() {
        let wanted = settings.onlyWakeForMe || settings.voiceNeedsMe
        seams.camera.setOwner(wanted ? faceSignature : nil)
    }

    private func noteIgnoredCommand() {
        guard engine.lastIgnoredCommand != nil else { return }
        voiceNeedsFaceNotice = true
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.voiceNeedsFaceNotice = false
        }
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
        if let setupWords {
            setupWords(transcript)
            return
        }
        guard let command = CommandParser.parse(transcript, triggerWord: settings.triggerWord) else { return }
        lastCommand = command
        send(.command(command))
    }

    private func applySampling() {
        if labRunning {
            seams.camera.setMode(.off)
        } else {
            seams.camera.setMode(previewing && engineMode == .off ? .checking : engineMode)
        }
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
            // Setup's voice step keeps the microphone on until it closes.
            if on { seams.voice.start() } else if setupWords == nil { seams.voice.stop() }
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
