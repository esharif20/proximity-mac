import Foundation
import Observation
// Scoped imports: the contract's `Observation` struct would shadow the Observation module the
// `@Observable` macro expands into.
import enum PresenceCore.Effect
import enum PresenceCore.Event
import enum PresenceCore.PresenceState
import struct PresenceCore.Settings

/// Runs the engine: feeds it idle time, ticks and observations, and executes the effects it returns.
/// No presence or timing rule lives here; the engine decides and this class only acts.
@MainActor @Observable
final class Coordinator {
    typealias Engine = StandInEngine

    private(set) var state: PresenceState
    /// Monotonic seconds at the last tick, so countdowns in the UI refresh once a second.
    private(set) var now: Double
    /// When the Grace countdown ends, while it is showing.
    private(set) var graceUntil: Double?
    private(set) var listening = false
    let bench: BenchMode?

    var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            store.save(settings)
            engine.update(settings: settings)
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
        self.state = .off
        self.now = ProcessInfo.processInfo.systemUptime

        seams.source.onObservation { [weak self] observation in
            Task { @MainActor in self?.send(.observation(observation)) }
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
        let effects = engine.handle(event, at: now)
        state = engine.state
        effects.forEach(perform)
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
        send(.tick)
    }

    private func perform(_ effect: Effect) {
        switch effect {
        case .screensOff: seams.display.screensOff()
        case .screensOn: seams.display.screensOn()
        case .lock: seams.display.lock()
        case .sample(let mode): seams.source.setMode(mode)
        case .listen(let on): listening = on
        case .showGrace(let seconds):
            graceUntil = now + Double(seconds)
            if !overlay.isShowing { overlay.show(GraceNotice(coordinator: self)) }
        case .hideGrace:
            graceUntil = nil
            overlay.hide()
        }
    }
}
