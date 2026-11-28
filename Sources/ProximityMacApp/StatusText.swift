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
