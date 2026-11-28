import Foundation
import PresenceCore

/// `--bench-mode <active|checking|away|listening|reading>` lets `scripts/bench.sh` measure one mode
/// without waiting for the engine to get there. The first four pin the engine; `reading` runs the
/// real engine against a person who sits still reading, so the check, seen, recheck cycle is measured.
enum BenchMode: String, CaseIterable {
    case active, checking, away, listening, reading

    /// Whether the engine is bypassed and the mode's effects are applied once at launch.
    var pinsEngine: Bool { self != .reading }

    /// In `reading`, every sighting is a person at a normal reading distance, so the engine keeps
    /// finding them and turns the camera off for `recheckAfterSeen`.
    func rewrite(_ observation: Observation) -> Observation {
        guard self == .reading else { return observation }
        return Observation(source: observation.source, person: true, distanceCm: 60, facingScreen: true)
    }

    init?(arguments: [String]) {
        guard let flag = arguments.firstIndex(of: "--bench-mode"),
              flag + 1 < arguments.count,
              let mode = BenchMode(rawValue: arguments[flag + 1])
        else { return nil }
        self = mode
    }

    var state: PresenceState {
        switch self {
        case .active, .listening, .reading: .present
        case .checking: .checking
        case .away: .away
        }
    }

    /// Screens stay on in every mode: the bench measures sensing cost, not the display.
    var effects: [Effect] {
        switch self {
        case .active: [.sample(.off), .listen(false)]
        case .checking: [.sample(.checking), .listen(false)]
        case .away: [.sample(.watching), .listen(false)]
        case .listening: [.sample(.off), .listen(true)]
        case .reading: []
        }
    }
}

/// Idle time for `--bench-mode reading`: it only grows, as if nobody touched the keyboard or mouse.
struct GrowingIdle: IdleReading {
    private let start = ProcessInfo.processInfo.systemUptime
    func secondsSinceInput() -> Double { ProcessInfo.processInfo.systemUptime - start }
}
