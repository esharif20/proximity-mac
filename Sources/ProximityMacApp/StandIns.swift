import Foundation
import PresenceCore
import Synchronization

// Temporary stand-ins so the app builds and runs before `PresenceEngine` (core) and `CameraSource`
// (sensors) land on main. Each is replaced by the real type in `Seams.live` and
// `Coordinator.Engine`, then this file goes away.

/// Mirrors the `PresenceEngine` API from the contract. It only follows the menu toggle and input,
/// so the menu and Settings can be exercised; every real timing rule belongs to `PresenceEngine`.
struct StandInEngine {
    private(set) var state: PresenceState = .off
    private var settings: Settings

    init(settings: Settings) { self.settings = settings }

    mutating func handle(_ event: Event, at now: Double) -> [Effect] {
        switch event {
        case .enable:
            state = .present
            return [.sample(.off)]
        case .disable:
            state = .off
            return [.sample(.off), .listen(false), .hideGrace, .screensOn]
        case .idle(let seconds) where state != .off:
            state = seconds < settings.idleBeforeCheck ? .present : .checking
            return []
        default:
            return []
        }
    }

    mutating func update(settings: Settings) { self.settings = settings }
}

/// Mirrors `CameraSource`: the contract's `PresenceSource` plus calibration.
final class StandInCamera: PresenceSource {
    let kind: SourceKind = .camera
    private let stored = Mutex<Calibration?>(nil)

    var calibration: Calibration? {
        get { stored.withLock { $0 } }
        set { stored.withLock { $0 = newValue } }
    }

    func setMode(_ mode: SamplingMode) {}
    func onObservation(_ handler: @escaping @Sendable (Observation) -> Void) {}
    func calibrate() async -> Calibration? { nil }
}
