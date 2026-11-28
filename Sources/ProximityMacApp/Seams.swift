import PresenceCore
import PresenceSensors

/// The hardware the Coordinator drives, gathered in one place so tests or a new source change one line.
struct Seams {
    /// Concrete because calibration is a camera feature, not part of `PresenceSource`.
    var camera: CameraSource
    /// Concrete because Monitors Off (`keepBuiltInOn`, restore) is not part of `DisplayControlling`.
    var display: DisplayControl
    var idle: any IdleReading
    var voice: any VoiceListening
    var mic: any MicUsageReading
    /// Concrete because the linked phone's `identifier` is not part of `PresenceSource`.
    var ble: BLESource
    var media: any MediaReading

    static var live: Seams {
        Seams(camera: CameraSource(), display: DisplayControl(), idle: IdleSource(),
              voice: VoiceSource(), mic: MicUsage(), ble: BLESource(), media: MediaUsage())
    }
}

/// The contract's `Observation`, for files where the Observation module's name would shadow it.
typealias PresenceObservation = PresenceCore.Observation
