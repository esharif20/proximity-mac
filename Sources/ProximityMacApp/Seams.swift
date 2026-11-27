import PresenceCore
import PresenceSensors

/// The hardware the Coordinator drives, gathered in one place so swapping in a real adapter is one line.
struct Seams {
    /// Concrete because calibration is a camera feature, not part of `PresenceSource`.
    typealias Camera = StandInCamera

    var camera: Camera
    var display: any DisplayControlling
    var idle: any IdleReading

    static var live: Seams {
        Seams(camera: Camera(), display: DisplayControl(), idle: IdleSource())
    }
}
