import Foundation

/// How a trace went against its ground-truth labels.
public struct TraceReport: Sendable, Equatable {
    /// Screens Off while the label says the person was at the desk.
    public var falseAways: Int
    /// Times the person left and the screens stayed on past the allowed delay.
    public var missedAways: Int
    /// Longest wait, in seconds, from the first sign of the person back at the desk to Screens On.
    public var maxWakeLatency: Double

    public init(falseAways: Int, missedAways: Int, maxWakeLatency: Double) {
        self.falseAways = falseAways
        self.missedAways = missedAways
        self.maxWakeLatency = maxWakeLatency
    }
}

public enum TraceReplay {
    /// Slack on top of the engine's own timers before a slow Away counts as missed.
    static let awaySlack = 2.0

    /// Replays the trace through a fresh, enabled engine. `truth` holds label changes, sorted by time;
    /// before the first one the person is taken to be at the desk.
    public static func run(_ lines: [TraceLine], truth: [(t: Double, atDesk: Bool)], settings: Settings) -> TraceReport {
        var engine = PresenceEngine(settings: settings)
        let lines = lines.sorted { $0.t < $1.t }
        _ = engine.handle(.enable, at: lines.first?.t ?? 0)

        func atDesk(_ t: Double) -> Bool { truth.last { $0.t <= t }?.atDesk ?? true }

        var report = TraceReport(falseAways: 0, missedAways: 0, maxWakeLatency: 0)
        var dark = false
        var lastInput = lines.first?.t ?? 0

        // The current spell away from the desk.
        var leftAt: Double?
        var awayCounted = false
        var askedForScreens = false
        // The first sign of the person back while the screens are dark.
        var backSince: Double?

        for line in lines {
            let t = line.t
            if !atDesk(t), leftAt == nil {
                leftAt = t
                awayCounted = dark
                askedForScreens = false
            } else if atDesk(t), leftAt != nil {
                leftAt = nil
            }

            switch line.event {
            case .idle(let seconds):
                // Same rule as the engine: input is the last-input time moving later.
                if t - seconds > lastInput + 0.05 { lastInput = t - seconds; evidence(t) }
            case .observation(let o) where o.person && (o.distanceCm ?? 0) <= settings.deskRadiusCm:
                if atDesk(t) { evidence(t) }
            case .command(.wake), .command(.hold):
                // Asking for the screens from across the room is not a missed Away.
                if leftAt != nil { askedForScreens = true }
            default:
                break
            }

            for effect in engine.handle(line.event, at: t) {
                switch effect {
                case .screensOff:
                    dark = true
                    if atDesk(t) { report.falseAways += 1 }
                    if leftAt != nil { awayCounted = true }
                case .screensOn:
                    dark = false
                    if let since = backSince { report.maxWakeLatency = max(report.maxWakeLatency, t - since) }
                    backSince = nil
                default:
                    break
                }
            }

            if let left = leftAt, !awayCounted, !askedForScreens {
                // The check cannot start before the idle timer runs out, so the budget counts from then.
                let start = max(left, lastInput + settings.idleBeforeCheck)
                let budget = settings.absenceBeforeAway + Double(settings.graceSeconds) + awaySlack
                if t > start + budget {
                    report.missedAways += 1
                    awayCounted = true
                }
            }
        }
        if let since = backSince, let end = lines.last?.t {
            report.maxWakeLatency = max(report.maxWakeLatency, end - since)
        }
        return report

        func evidence(_ t: Double) {
            if dark, backSince == nil { backSince = t }
        }
    }
}
