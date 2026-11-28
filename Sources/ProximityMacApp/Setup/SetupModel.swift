import Foundation
import Observation
import enum PresenceCore.Command
import enum PresenceCore.CommandParser
import struct PresenceCore.Calibration
import struct PresenceCore.PhoneLink
import class PresenceSensors.BLESource
import struct PresenceSensors.FoundDevice
import class PresenceSensors.VisionLab
import struct PresenceSensors.LabFrame

/// The Setup walkthrough's state. The vision runs only while the window is open; nothing it sees is
/// kept beyond the latest frame.
@MainActor @Observable
final class SetupModel {
    enum Step: Int, CaseIterable {
        case welcome, sit, leanBack, monitors, bed, phone, owner, voice, lockScreen, done
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

    /// Named devices heard in the phone step. Order is kept between scans so rows do not jump.
    private(set) var devices: [FoundDevice] = []
    private(set) var chosenDevice: FoundDevice?
    /// The chosen device's smoothed signal, about every 2 s.
    private(set) var phoneSignal: Double?
    private(set) var nearRssi: Double?
    private(set) var farRssi: Double?
    private(set) var isMeasuringPhone = false
    /// The last measurement heard nothing from the device.
    private(set) var phoneNotHeard = false

    let coordinator: Coordinator
    static let enrolTotal = 20
    /// Margin added beyond the farthest counted position, so leaning back a little more still counts.
    static let radiusMarginCm = 20.0
    /// Below this gap the desk and the far spot overlap once a hand or a body blocks the signal.
    static let minPhoneGapDb = 8.0
    static let phoneMeasureSeconds = 5.0

    @ObservationIgnored private let lab = VisionLab()
    @ObservationIgnored private var running = false
    @ObservationIgnored private var cpuSample: (wall: Double, cpu: Double)?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Created on entering the phone step, so the Bluetooth prompt appears only then.
    @ObservationIgnored private var ble: BLESource?
    @ObservationIgnored private var phoneTask: Task<Void, Never>?
    @ObservationIgnored private var phoneSamples: [Double]?

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
        lab.calibration = coordinator.settings.calibration
        lab.start { [weak self] frame in
            Task { @MainActor in self?.received(frame) }
        }
    }

    func close() {
        guard running else { return }
        running = false
        task?.cancel()
        stopPhone()
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
        if step == .phone { stopPhone() }
        self.direction = direction
        step = next
        switch next {
        case .sit: if !calibrated { calibrate() }
        case .leanBack: farthestCountedCm = nil
        case .monitors: lookedAt = []
        case .voice: startVoice()
        case .phone: startPhone()
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
                lab.calibration = calibration
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
            if let signature, coordinator.saveFaceSignature(signature) {
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

    // MARK: Phone or watch

    /// The near and far levels are too close to tell the desk from the far spot.
    var phoneGapTooSmall: Bool {
        guard let nearRssi, let farRssi else { return false }
        return nearRssi - farRssi < Self.minPhoneGapDb
    }

    var phoneLinked: Bool {
        guard let chosenDevice, let phone = coordinator.settings.phone else { return false }
        return phone.identifier == chosenDevice.id
    }

    func choose(_ device: FoundDevice) {
        chosenDevice = device
        nearRssi = nil
        farRssi = nil
        phoneNotHeard = false
        phoneSignal = device.rssi
        phoneTask?.cancel()
        ble?.identifier = device.id
        ble?.setMode(.checking)
    }

    func chooseAnotherDevice() {
        chosenDevice = nil
        nearRssi = nil
        farRssi = nil
        phoneSignal = nil
        phoneNotHeard = false
        isMeasuringPhone = false
        ble?.setMode(.off)
        ble?.identifier = nil
        scanForDevices()
    }

    /// Records the median signal over 5 s: at the desk first, then at the far spot.
    func measurePhone(near measuringNear: Bool) {
        guard let chosenDevice, !isMeasuringPhone else { return }
        if measuringNear { nearRssi = nil }
        farRssi = nil
        phoneNotHeard = false
        isMeasuringPhone = true
        phoneSamples = []
        phoneTask = Task {
            try? await Task.sleep(for: .seconds(Self.phoneMeasureSeconds))
            let samples = phoneSamples ?? []
            phoneSamples = nil
            isMeasuringPhone = false
            guard !Task.isCancelled else { return }
            guard let level = Self.median(samples) else {
                phoneNotHeard = true
                return
            }
            if measuringNear {
                nearRssi = level
                return
            }
            farRssi = level
            if let nearRssi, !phoneGapTooSmall {
                coordinator.settings.phone = PhoneLink(
                    identifier: chosenDevice.id, name: chosenDevice.name, nearRssi: nearRssi, farRssi: level)
            }
        }
    }

    private func startPhone() {
        let ble = self.ble ?? BLESource()
        self.ble = ble
        ble.onObservation { [weak self] observation in
            guard let rssi = observation.rssi else { return }
            Task { @MainActor in self?.heardPhone(rssi) }
        }
        if let chosenDevice {
            ble.identifier = chosenDevice.id
            ble.setMode(.checking)
        } else {
            scanForDevices()
        }
    }

    private func stopPhone() {
        phoneTask?.cancel()
        phoneTask = nil
        phoneSamples = nil
        isMeasuringPhone = false
        ble?.setMode(.off)
    }

    private func scanForDevices() {
        guard let ble else { return }
        phoneTask?.cancel()
        phoneTask = Task {
            while !Task.isCancelled, chosenDevice == nil {
                let found = await ble.scan(seconds: 1.5)
                guard !Task.isCancelled else { return }
                devices = Self.merge(devices, found)
            }
        }
    }

    private func heardPhone(_ rssi: Double) {
        guard step == .phone, chosenDevice != nil else { return }
        phoneSignal = rssi
        phoneSamples?.append(rssi)
    }

    /// Updates the rows in place and adds new devices at the end, strongest first among themselves. A device
    /// missing from one short scan keeps its row, since idle phones advertise less often.
    static func merge(_ current: [FoundDevice], _ found: [FoundDevice]) -> [FoundDevice] {
        let byID = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let kept = current.map { byID[$0.id] ?? $0 }
        let keptIDs = Set(kept.map(\.id))
        return kept + found.filter { !keptIDs.contains($0.id) }
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
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
