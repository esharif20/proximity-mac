import PresenceCore

// Stand-ins for GH-52 and GH-53 under the contract's names, so the wiring builds before those
// lanes merge. Delete this file after `git merge main` brings in the real ones.

struct MediaUsage: MediaReading {
    init() {}
    func mediaPlaying() -> Bool { false }
}

extension PresenceEngine {
    var reason: PresenceReason {
        switch state {
        case .off: .turnedOff
        case .present: .typing
        case .checking: .checking
        case .grace, .away: .nobodySeen
        case .hold: .holdCommand
        }
    }
}
