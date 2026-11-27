import Foundation

// The shared contract between the engine, the sensors and the app.
// Owned by the Lead: ask before changing a signature here.
// Times are monotonic seconds (for example `ProcessInfo.processInfo.systemUptime`), never wall-clock dates.

/// Where an observation came from. New hardware adds a case; the engine treats every source the same way.
public enum SourceKind: String, Codable, Sendable, CaseIterable {
    case camera
    case radar
    case ble
}

/// One reading from a presence source. Numbers only: never images, audio or device names.
public struct Observation: Codable, Sendable, Equatable {
    public var source: SourceKind
    /// A face or an upper body was detected.
    public var person: Bool
    /// Estimated distance from the screen in centimetres, when the source can tell.
    public var distanceCm: Double?
    /// Head yaw and pitch are within the "looking at the screen" limits, when the source can tell.
    public var facingScreen: Bool?

    public init(source: SourceKind, person: Bool, distanceCm: Double? = nil, facingScreen: Bool? = nil) {
        self.source = source
        self.person = person
        self.distanceCm = distanceCm
        self.facingScreen = facingScreen
    }
}

/// A spoken command, already parsed. "Screen, wake up" / "Screen, go to sleep" / "Screen, keep it on for 10 minutes".
public enum Command: Codable, Sendable, Equatable {
    case wake
    case sleep
    case hold(minutes: Int)
}

/// Everything the engine reacts to. The app feeds these in; traces record them.
public enum Event: Codable, Sendable, Equatable {
    /// The menu-bar toggle.
    case enable
    case disable
    /// Seconds since the last keyboard or mouse input, polled about once a second.
    case idle(seconds: Double)
    case observation(Observation)
    case command(Command)
    /// Another app is using the microphone (a call), so the app must not listen.
    case micBusy(Bool)
    /// A timer tick so deadlines (grace, hold, absence) fire without new input.
    case tick
}

/// How often a presence source samples. Off costs nothing.
public enum SamplingMode: String, Codable, Sendable {
    /// Source stopped: camera and Vision fully off.
    case off
    /// Idle at the desk: about 1 sample per second to decide whether the person left.
    case checking
    /// Away: about 1 sample every 2 seconds to notice the person coming back.
    case watching
}

/// What the engine asks the outside world to do. The app executes these and nothing else.
public enum Effect: Codable, Sendable, Equatable {
    /// All displays dark, Mac stays awake. Never System Sleep.
    case screensOff
    case screensOn
    /// Lock the session. Only when `Settings.lockWhenAway` is on.
    case lock
    case sample(SamplingMode)
    case listen(Bool)
    case showGrace(seconds: Int)
    case hideGrace
}

/// The engine's state, shown in the menu bar.
public enum PresenceState: Codable, Sendable, Equatable {
    /// Toggled off in the menu bar: no sensing at all.
    case off
    /// The person is at the desk (recent input or seen close).
    case present
    /// Idle long enough that the camera is checking whether anyone is still there.
    case checking
    /// Nobody seen for long enough; the countdown overlay is up until `until`.
    case grace(until: Double)
    /// Screens Off; watching for the person to come back.
    case away
    /// Screens kept on by a command. `until == nil` means until "go to sleep" or back at the desk.
    case hold(until: Double?)
}

/// What "Screen, wake up" does after waking.
public enum WakeUpMode: String, Codable, Sendable {
    /// Stay on until "go to sleep" or the person sits back at the desk (default).
    case untilSleepOrDesk
    /// Same as a Hold of `Settings.wakeUpHoldMinutes`.
    case timedHold
}

/// One user's camera calibration: face width in pixels while sitting normally.
public struct Calibration: Codable, Sendable, Equatable {
    public var faceWidthPx: Double
    public var imageWidthPx: Double
    /// The distance the person was sitting at when calibrating.
    public var distanceCm: Double

    public init(faceWidthPx: Double, imageWidthPx: Double, distanceCm: Double = 60) {
        self.faceWidthPx = faceWidthPx
        self.imageWidthPx = imageWidthPx
        self.distanceCm = distanceCm
    }
}

public struct Settings: Codable, Sendable, Equatable {
    /// Seconds without input before the camera starts checking.
    public var idleBeforeCheck: Double = 30
    /// Seconds of continuous absence while checking before the grace countdown.
    public var absenceBeforeAway: Double = 30
    /// Length of the countdown overlay before Screens Off.
    public var graceSeconds: Int = 10
    /// After seeing the person while checking, seconds before checking again (camera off meanwhile).
    public var recheckAfterSeen: Double = 60
    /// A person counts as Present only within this distance of the screen.
    public var deskRadiusCm: Double = 120
    public var voiceEnabled: Bool = true
    /// Seconds without input before the microphone listens for commands.
    public var listenAfterIdle: Double = 30
    /// Commands must start with this word ("Screen, wake up").
    public var triggerWord: String = "screen"
    public var lockWhenAway: Bool = false
    public var wakeUpMode: WakeUpMode = .untilSleepOrDesk
    public var wakeUpHoldMinutes: Int = 30
    public var calibration: Calibration?

    public init() {}
}

/// One line of a trace file (JSONL): an event at a monotonic time.
public struct TraceLine: Codable, Sendable, Equatable {
    public var t: Double
    public var event: Event

    public init(t: Double, event: Event) {
        self.t = t
        self.event = event
    }
}

// MARK: - Seams the app wires together. Sensors implement these; tests use fakes.

/// A presence source (camera now; radar or BLE later).
public protocol PresenceSource: AnyObject, Sendable {
    var kind: SourceKind { get }
    /// Start delivering observations at the given rate; `.off` stops the hardware completely.
    func setMode(_ mode: SamplingMode)
    /// Called on an arbitrary queue for each sample.
    func onObservation(_ handler: @escaping @Sendable (Observation) -> Void)
}

public protocol DisplayControlling: Sendable {
    func screensOff()
    func screensOn()
    func lock()
}

public protocol IdleReading: Sendable {
    /// Seconds since the last keyboard or mouse event.
    func secondsSinceInput() -> Double
}

/// Listens for speech and hands back raw transcripts; parsing is `CommandParser`'s job.
public protocol VoiceListening: AnyObject, Sendable {
    func start()
    func stop()
    func onTranscript(_ handler: @escaping @Sendable (String) -> Void)
}

public protocol MicUsageReading: Sendable {
    /// True when another app is capturing from the default input (for example a call).
    func micInUseByOtherApp() -> Bool
}
