import PresenceCore

/// The words the menu shows for each state. The icon is drawn by `MenuBarIcon`.
enum StatusText {
    static func line(_ state: PresenceState, now: Double) -> String {
        switch state {
        case .off: "Off"
        case .present: "Present"
        case .checking: "Checking"
        case .grace(let until): "Screens off in \(secondsLeft(until, now)) s"
        case .away: "Away"
        case .hold(nil): "Held until you sleep it"
        case .hold(let until?): "Held for \(minutesLeft(until, now)) min"
        }
    }

    /// The menu's Why line for `PresenceEngine.reason`.
    static func why(_ reason: PresenceReason, idleSeconds: Double, distanceCm: Double?, unseenSeconds: Double) -> String? {
        switch reason {
        case .turnedOff: nil
        case .typing: "You typed \(duration(idleSeconds)) ago"
        case .seenClose, .ownerSeen: distanceCm.map { "Face seen at \(Int($0.rounded())) cm" } ?? "Face seen"
        case .phoneNear: "Your phone is near"
        case .mediaPlaying: "A video is playing"
        case .command: "Woken by voice"
        case .holdCommand: "Held on by voice"
        case .checking: "Looking for you"
        case .nobodySeen: "Nobody seen for \(duration(unseenSeconds))"
        case .phoneLeft: "Your phone left"
        case .sleepCommand: "Turned off by voice"
        case .stoppedWatching: "Camera stopped for the night"
        }
    }

    /// "3 s" under a minute and a half, then whole minutes, so a night Away does not read "5412 s".
    static func duration(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return s < 90 ? "\(s) s" : "\(s / 60) min"
    }

    static func secondsLeft(_ until: Double, _ now: Double) -> Int {
        max(0, Int((until - now).rounded(.up)))
    }

    static func minutesLeft(_ until: Double, _ now: Double) -> Int {
        max(0, Int(((until - now) / 60).rounded(.up)))
    }

    static func command(_ command: Command) -> String {
        switch command {
        case .wake: "Wake up"
        case .sleep: "Go to sleep"
        case .hold(let minutes): "Keep on for \(minutes) min"
        }
    }
}
