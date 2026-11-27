import PresenceCore
import PresenceSensors

/// The hardware the Coordinator drives, gathered in one place so tests or a new source change one line.
struct Seams {
    /// Concrete because calibration is a camera feature, not part of `PresenceSource`.
    var camera: CameraSource
    var display: any DisplayControlling
    var idle: any IdleReading
    var voice: any VoiceListening
    var mic: any MicUsageReading

    static var live: Seams {
        Seams(camera: CameraSource(), display: DisplayControl(), idle: IdleSource(),
              voice: VoiceSource(), mic: MicUsage())
    }
}
