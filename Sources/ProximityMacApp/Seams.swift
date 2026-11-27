import PresenceCore
import PresenceSensors

/// The hardware the Coordinator drives, gathered in one place so swapping in a real adapter is one line.
struct Seams {
    var source: any PresenceSource
    var display: any DisplayControlling
    var idle: any IdleReading

    static var live: Seams {
        Seams(source: StandInSource(), display: StandInDisplay(), idle: StandInIdle())
    }
}
