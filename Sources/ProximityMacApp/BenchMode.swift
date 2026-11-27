import PresenceCore

/// `--bench-mode <active|checking|away|listening>` pins the app in one mode so `scripts/bench.sh`
/// can measure what that mode costs without waiting for the engine to get there.
enum BenchMode: String, CaseIterable {
    case active, checking, away, listening

    init?(arguments: [String]) {
        guard let flag = arguments.firstIndex(of: "--bench-mode"),
              flag + 1 < arguments.count,
              let mode = BenchMode(rawValue: arguments[flag + 1])
        else { return nil }
        self = mode
    }

    var state: PresenceState {
        switch self {
        case .active, .listening: .present
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
        }
    }
}
