import Foundation
import Observation
import enum PresenceCore.Command
import enum PresenceCore.CommandParser
import struct PresenceCore.Calibration

/// The Setup walkthrough's state. The vision runs only while the window is open; nothing it sees is
/// kept beyond the latest frame.
@MainActor @Observable
final class SetupModel {
    enum Step: Int, CaseIterable {
        case welcome, sit, leanBack, monitors, bed, owner, voice, done
    }

    enum Direction { case forward, back }

    private(set) var step = Step.welcome
    private(set) var direction = Direction.forward
    private(set) var frame: LabFrame?
    /// Process CPU over the last second, for the HUD.
    private(set) var cpuPercent: Double = 0

    private(set) var isCalibrating = false
    private(set) var calibrated = false
    /// The farthest distance the face was seen at in the lean-back step.
    private(set) var farthestCountedCm: Double?
    private(set) var lookedAt: Set<GazeTarget> = []
    private(set) var enrolSamples = 0
    private(set) var isEnrolling = false
    private(set) var enrolled = false
    private(set) var voiceLevel: Float = 0
    private(set) var heardWords: String?
    private(set) var heardCommand: Command?

    let coordinator: Coordinator
    static let enrolTotal = 20
    /// Margin added beyond the farthest counted position, so leaning back a little more still counts.
    static let radiusMarginCm = 20.0

    @ObservationIgnored private let lab = VisionLab()
    @ObservationIgnored private var running = false
    @ObservationIgnored private var cpuSample: (wall: Double, cpu: Double)?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(coordinator: Coordinator) {
        self.coordinator = coordinator
    }

    var radiusCm: Double {
        get { coordinator.settings.deskRadiusCm }
        set { coordinator.settings.deskRadiusCm = min(Self.maxRadius, max(Self.minRadius, newValue.rounded())) }
    }

    static let minRadius = 40.0
    static let maxRadius = 300.0

    /// Whether the face in the latest frame sits inside the desk radius.
    var counted: Bool? {
        guard let face = frame?.face else { return nil }
        return face.distanceCm <= radiusCm
    }

    var showsCamera: Bool { step != .welcome && step != .done }

    // MARK: Lifecycle

    func open() {
        guard !running else { return }
        running = true
        // Only one camera session at a time: the presence camera stands down while Setup watches.
        coordinator.setLabRunning(true)
        lab.start { [weak self] frame in
            Task { @MainActor in self?.received(frame) }
        }
    }

    func close() {
        guard running else { return }
        running = false
        task?.cancel()
        lab.stop()
        coordinator.setLabRunning(false)
        coordinator.stopSetupVoice()
        coordinator.settings.setupDone = true
    }

    // MARK: Navigation

    func next() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        go(to: next, .forward)
    }

    func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        go(to: previous, .back)
    }

    private func go(to next: Step, _ direction: Direction) {
        if step == .voice { coordinator.stopSetupVoice() }
        self.direction = direction
        step = next
        switch next {
        case .sit: if !calibrated { calibrate() }
        case .leanBack: farthestCountedCm = nil
        case .monitors: lookedAt = []
        case .voice: startVoice()
        default: break
        }
    }

    // MARK: Steps

    func calibrate() {
        guard !isCalibrating else { return }
        isCalibrating = true
        task = Task {
            let calibration = await lab.calibrate()
            isCalibrating = false
            if let calibration {
                coordinator.settings.calibration = calibration
                calibrated = true
            }
        }
    }

    func shrinkRadius(below distance: Double) {
        radiusCm = distance - Self.radiusMarginCm
    }

    func enrol() {
        guard !isEnrolling else { return }
        isEnrolling = true
        enrolSamples = 0
        task = Task {
            let signature = await lab.enrolOwner(samples: Self.enrolTotal) { [weak self] count in
                Task { @MainActor in self?.enrolSamples = count }
            }
            isEnrolling = false
            if let signature {
                coordinator.saveFaceSignature(signature)
                enrolled = true
            }
        }
    }

    func skipOwner() {
        coordinator.settings.onlyWakeForMe = false
        coordinator.settings.voiceNeedsMe = false
        next()
    }

    private func startVoice() {
        heardWords = nil
        heardCommand = nil
        coordinator.startSetupVoice(
            onLevel: { [weak self] level in self?.voiceLevel = level },
            onWords: { [weak self] words in
                guard let self else { return }
                heardWords = words
                if let command = CommandParser.parse(words, triggerWord: coordinator.settings.triggerWord) {
                    heardCommand = command
                }
            })
    }

    // MARK: Frames

    private func received(_ frame: LabFrame) {
        guard running else { return }
        self.frame = frame
        sampleCPU()
        guard let face = frame.face else { return }
        switch step {
        case .leanBack:
            if face.distanceCm > (farthestCountedCm ?? 0) {
                farthestCountedCm = face.distanceCm
                radiusCm = face.distanceCm + Self.radiusMarginCm
            }
        case .monitors:
            let target = GazeTarget(yawDeg: face.yawDeg)
            if !lookedAt.contains(target) { lookedAt.insert(target) }
        default:
            break
        }
    }

    private func sampleCPU() {
        let wall = ProcessInfo.processInfo.systemUptime
        let cpu = Double(clock()) / Double(CLOCKS_PER_SEC)
        guard let last = cpuSample else { cpuSample = (wall, cpu); return }
        guard wall - last.wall >= 1 else { return }
        cpuPercent = (cpu - last.cpu) / (wall - last.wall) * 100
        cpuSample = (wall, cpu)
    }
}

/// Where the head is pointing, in the selfie-mirrored view the person sees.
enum GazeTarget: CaseIterable {
    case left, centre, right

    /// Beyond this yaw the head is taken to point at a side monitor.
    static let sideYawDeg = 15.0

    init(yawDeg: Double) {
        self = yawDeg < -Self.sideYawDeg ? .left : yawDeg > Self.sideYawDeg ? .right : .centre
    }
}
