@preconcurrency import AVFoundation
import Foundation
import Synchronization
import Vision

/// The camera as a presence source: a low-resolution capture that runs only while sampling, with Vision
/// face, body pose and hand pose on a few frames a second at most, and only when something moves.
///
/// Frames never leave this file: each one is analysed in memory and dropped, never stored or logged.
///
/// `@unchecked Sendable`: the capture session is touched only on `sessionQueue`, frames only on
/// `frameQueue`, and every other piece of state is behind `state`.
public final class CameraSource: PresenceSource, @unchecked Sendable {
    public let kind = SourceKind.camera

    private struct State {
        var mode = SamplingMode.off
        var throttle = FrameThrottle(interval: nil)
        var schedule = VisionSchedule(mode: .off)
        var motion = MotionGate()
        var gridThrottle = FrameThrottle(interval: nil)
        /// From the latest grid, at most `gridInterval` old when a sample is taken.
        var brightness: Double?
        var handler: (@Sendable (Observation) -> Void)?
        var calibration: Calibration?
        /// Face widths collected while `calibrate()` runs; nil otherwise.
        var calibrationWidths: [Double]?
        /// When calibration saw its first frame, so its 3 s window excludes camera warm-up.
        var calibrationStart: Double?
        /// The owner's face signature; nil means recognition is off and no model is loaded.
        var signature: FaceSignature?
        /// An owner check in progress, holding its sample until the following frames decide `owner`.
        var ownerCheck: OwnerCheck?

        var wantsCamera: Bool { mode != .off || calibrationWidths != nil }
    }

    private let state = Mutex(State())
    private let sessionQueue = DispatchQueue(label: "camera.session")
    private let frameQueue = DispatchQueue(label: "camera.frames")
    private var session: AVCaptureSession?
    private lazy var delegate = FrameDelegate(owner: self)
    /// Built once and used only on `frameQueue`: rebuilding Vision requests per frame reloads their models.
    private lazy var vision = VisionPipeline()
    /// Created on `frameQueue` the first time a signature is set, so the model loads only when needed.
    private var recognizer: FaceRecognizer?

    public init() {}

    /// The person's calibration, set by the Coordinator from Settings.
    public var calibration: Calibration? {
        get { state.withLock { $0.calibration } }
        set { state.withLock { $0.calibration = newValue } }
    }

    public func onObservation(_ handler: @escaping @Sendable (Observation) -> Void) {
        state.withLock { $0.handler = handler }
    }

    /// Turns owner recognition on with the owner's signature, or off with nil.
    public func setOwner(_ signature: FaceSignature?) {
        state.withLock { s in
            s.signature = signature
            s.ownerCheck = nil
        }
    }

    public func setMode(_ mode: SamplingMode) {
        state.withLock { s in
            s.mode = mode
            s.ownerCheck = nil
            s.schedule = VisionSchedule(mode: mode)
            s.motion.reset()
            s.gridThrottle = FrameThrottle(interval: mode == .off ? nil : CameraSource.gridInterval)
            s.brightness = nil
            if s.calibrationWidths == nil { s.throttle = FrameThrottle(interval: FrameThrottle.interval(for: mode)) }
        }
        reconcile()
    }

    static let calibrationSeconds = 3.0
    /// Gives up if the camera delivers nothing for this long (no camera, or permission denied).
    static let calibrationTimeout = 8.0

    /// Samples about 3 s of frames, counted from the first delivered frame, then restores the previous mode.
    public func calibrate() async -> Calibration? {
        state.withLock { s in
            s.calibrationWidths = []
            s.calibrationStart = nil
            s.ownerCheck = nil
            s.throttle = FrameThrottle(interval: 0.1)
        }
        reconcile()
        let began = ProcessInfo.processInfo.systemUptime
        while !Task.isCancelled {
            let now = ProcessInfo.processInfo.systemUptime
            let start = state.withLock { $0.calibrationStart }
            if let start, now - start >= Self.calibrationSeconds { break }
            if start == nil, now - began >= Self.calibrationTimeout { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let widths = state.withLock { s -> [Double] in
            defer {
                s.calibrationWidths = nil
                s.calibrationStart = nil
                s.throttle = FrameThrottle(interval: FrameThrottle.interval(for: s.mode))
            }
            return s.calibrationWidths ?? []
        }
        reconcile()
        return Distance.calibration(
            fromFaceWidths: widths, imageWidthPx: CameraSource.captureWidthPx, distanceCm: Calibration.defaultDistanceCm)
    }

    // MARK: - Capture

    /// The 640x480 preset is the lowest one Vision still finds faces with at desk distance.
    static let captureWidthPx = 640.0

    /// Brings the camera in line with the state as it is when this runs on `sessionQueue`, not when it
    /// was asked for, so a stop and a start racing from two threads always settle on the latest state.
    private func reconcile() {
        sessionQueue.async { [self] in
            let (running, calibrating, mode) = state.withLock { ($0.wantsCamera, $0.calibrationWidths != nil, $0.mode) }
            if running {
                if session == nil { session = makeSession() }
                guard let session else { return }
                if !session.isRunning { session.startRunning() }
                // Set after starting: starting a session can put the device back on its default durations.
                if let device = (session.inputs.first as? AVCaptureDeviceInput)?.device {
                    Self.setFrameRate(device, mode: mode, calibrating: calibrating)
                }
            } else if let session {
                // Stopping and dropping the session powers the camera down, so the light goes off.
                session.stopRunning()
                self.session = nil
            }
        }
    }

    private func makeSession() -> AVCaptureSession? {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device)
        else { return nil }
        let session = AVCaptureSession()
        session.beginConfiguration()
        guard session.canAddInput(input) else { return nil }
        session.addInput(input)
        // The smallest format the device offers: fewer pixels to move and to analyse on every frame.
        let formats = device.formats.map { format -> (width: Int, height: Int, minFps: Double) in
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let minFps = format.videoSupportedFrameRateRanges.map(\.minFrameRate).min() ?? 30
            return (Int(size.width), Int(size.height), minFps)
        }
        if let index = Self.smallestFormatIndex(formats), (try? device.lockForConfiguration()) != nil {
            device.activeFormat = device.formats[index]
            device.unlockForConfiguration()
        } else {
            session.sessionPreset = session.canSetSessionPreset(.vga640x480) ? .vga640x480 : .low
        }
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        // The default output is 2vuy, which costs a conversion on every frame, sampled or not. The camera's
        // own pixel format (420v on built-in cameras) is delivered as is, and Vision reads it directly.
        // Measured on a bare session: 4.3% CPU with the default, 2.9% native.
        let native = CMFormatDescriptionGetMediaSubType(device.activeFormat.formatDescription)
        if output.availableVideoPixelFormatTypes.contains(native) {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: native]
        }
        output.setSampleBufferDelegate(delegate, queue: frameQueue)
        guard session.canAddOutput(output) else { return nil }
        session.addOutput(output)
        session.commitConfiguration()
        return session
    }

    private static func setFrameRate(_ device: AVCaptureDevice, mode: SamplingMode, calibrating: Bool) {
        let ranges = device.activeFormat.videoSupportedFrameRateRanges.map { (min: $0.minFrameRate, max: $0.maxFrameRate) }
        guard let rates = frameRates(ranges: ranges, mode: mode, calibrating: calibrating),
              (try? device.lockForConfiguration()) != nil
        else { return }
        func duration(_ fps: Double) -> CMTime { CMTime(value: 1000, timescale: CMTimeScale((fps * 1000).rounded())) }
        device.activeVideoMinFrameDuration = duration(rates.fastest)
        device.activeVideoMaxFrameDuration = duration(rates.slowest)
        device.unlockForConfiguration()
    }

    /// The motion gate checks about 8 frames a second, so watching needs no more than that.
    static let motionFrameRate = 8.0

    /// Below this `Observation.brightness` the camera cannot see a person, so "nobody seen" means
    /// "too dark to see you". Not yet tuned from a dark reading: see docs/spikes/display-and-camera.md.
    public static let darkBrightness = 0.08

    /// The frame rate range to give the device. Watching lets auto exposure stretch frames down to the
    /// slowest rate the camera allows, so a dim room still gives a usable picture; it runs no faster than
    /// the motion gate needs. Checking and calibration keep one fixed rate, as before.
    static func frameRates(
        ranges: [(min: Double, max: Double)], mode: SamplingMode, calibrating: Bool
    ) -> (fastest: Double, slowest: Double)? {
        guard let fixed = sensorFrameRate(ranges: ranges, calibrating: calibrating) else { return nil }
        guard mode == .watching, !calibrating else { return (fixed, fixed) }
        let fastest = ranges.contains { $0.min <= motionFrameRate && motionFrameRate <= $0.max }
            ? motionFrameRate : max(fixed, ranges.filter { $0.max < motionFrameRate }.map(\.max).max() ?? fixed)
        return (fastest, fixed)
    }

    /// Faces stop being found reliably below this width at desk distance.
    static let minUsableWidth = 320

    /// The format with the fewest pixels, at least `minUsableWidth` wide; ties go to the lowest frame rate.
    static func smallestFormatIndex(_ formats: [(width: Int, height: Int, minFps: Double)]) -> Int? {
        formats.indices
            .filter { formats[$0].width >= minUsableWidth }
            .min { a, b in
                let (fa, fb) = (formats[a], formats[b])
                return (fa.width * fa.height, fa.minFps) < (fb.width * fb.height, fb.minFps)
            }
    }

    /// The slowest rate the camera allows while sampling: the throttle's early tolerance keeps every
    /// sample even at 1 fps. Calibration runs at 10 fps or more to collect plenty of face widths in 3 s.
    /// Built-in cameras often bottom out at 15 fps; some external ones go down to 1 fps.
    static func sensorFrameRate(ranges: [(min: Double, max: Double)], calibrating: Bool) -> Double? {
        guard calibrating else { return ranges.map(\.min).min() }
        let target = 10.0
        if ranges.contains(where: { $0.min <= target && target <= $0.max }) { return target }
        let above = ranges.filter { $0.min > target }.map(\.min).min()
        return above ?? ranges.map(\.max).max()
    }

    // MARK: - Frames

    /// About 8 motion checks a second: twice the motion sample rate, so a wave is seen on the next pass.
    static let gridInterval = 0.125

    fileprivate func handle(_ sampleBuffer: CMSampleBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Locking a frame's pixels costs about 0.3 ms, so the grid is taken on a few frames a second, not all.
        let wantsGrid = state.withLock { $0.gridThrottle.shouldSample(at: now) }
        let grid = wantsGrid ? LumaGrid(sampling: pixels) : nil
        let (take, calibrating, continuing, signature, brightness, moved) = state.withLock { s in
            if s.calibrationWidths != nil, s.calibrationStart == nil { s.calibrationStart = now }
            if let check = s.ownerCheck, check.isStale(at: now) { s.ownerCheck = nil }
            let moved = grid.map { s.motion.update($0) } ?? false
            if let grid { s.brightness = grid.brightness }
            // The frames right after a sample finish its owner check, whatever the throttle says.
            if s.ownerCheck != nil {
                if moved { s.schedule.noteMotion() }
                return (true, false, true, s.signature, s.brightness, moved)
            }
            if s.calibrationWidths != nil {
                return (s.throttle.shouldSample(at: now), true, false, s.signature, s.brightness, moved)
            }
            let pass = s.schedule.shouldRun(at: now, moved: moved)
            return (pass != nil, false, false, s.signature, s.brightness, pass == .motion)
        }
        guard take else { return }
        vision.dropIdlePoses()
        let imageWidth = Double(CVPixelBufferGetWidth(pixels))

        if continuing, let signature {
            // The largest face is the one checked, so a larger stranger in front makes the answer false.
            let match = vision.largestFace(in: pixels, imageWidth: imageWidth)
                .map { ownerMatches(pixels, face: $0.observation, signature: signature) } ?? false
            finishOwnerCheck(match)
            return
        }

        guard let face = vision.largestFace(in: pixels, imageWidth: imageWidth) else {
            if calibrating { return }
            let (handler, calibration) = state.withLock { ($0.handler, $0.calibration) }
            handler?(withoutFace(pixels, moved: moved, calibration: calibration, brightness: brightness))
            return
        }
        if calibrating {
            state.withLock { $0.calibrationWidths?.append(face.measure.widthPx * Self.captureWidthPx / imageWidth) }
            return
        }
        let (handler, calibration) = state.withLock { ($0.handler, $0.calibration) }
        let observation = Self.observation(
            face: face.measure, bodyWidthPx: nil, imageWidthPx: imageWidth, calibration: calibration, brightness: brightness)
        guard let signature, OwnerCheck.wanted(for: observation) else {
            handler?(observation)
            return
        }
        let match = ownerMatches(pixels, face: face.observation, signature: signature)
        state.withLock { $0.ownerCheck = OwnerCheck(observation: observation, started: now) }
        finishOwnerCheck(match)
    }

    /// Bodies and hands only when there is no face: a face already answers "person" and gives a better distance.
    /// On motion frames only, body pose first, since it sees a torso with the head above the frame, then
    /// hands, since a hand that counts is a wave. Someone who just stood up or waved has moved, and an empty
    /// still room then costs only the face and upper-body passes. The upper-body box comes last.
    private func withoutFace(
        _ pixels: CVPixelBuffer, moved: Bool, calibration: Calibration?, brightness: Double?
    ) -> Observation {
        let imageWidth = Double(CVPixelBufferGetWidth(pixels))
        if moved, let body = vision.bodyJoints(in: pixels),
           let observation = Self.observation(body: body, imageWidthPx: imageWidth, calibration: calibration, brightness: brightness) {
            return observation
        }
        if moved, let observation = Self.observation(
            hands: vision.handJoints(in: pixels), imageWidthPx: imageWidth, calibration: calibration, brightness: brightness) {
            return observation
        }
        let bodyWidth = vision.widestUpperBody(in: pixels).map { $0 * imageWidth }
        return Self.observation(
            face: nil, bodyWidthPx: bodyWidth, imageWidthPx: imageWidth, calibration: calibration, brightness: brightness)
    }

    /// Records one frame's answer and delivers the held sample once the check has decided.
    private func finishOwnerCheck(_ match: Bool) {
        let decided = state.withLock { s -> (Observation, (@Sendable (Observation) -> Void)?)? in
            guard var check = s.ownerCheck else { return nil }
            guard let owner = check.record(match) else {
                s.ownerCheck = check
                return nil
            }
            s.ownerCheck = nil
            var observation = check.observation
            observation.owner = owner
            return (observation, s.handler)
        }
        if let (observation, handler) = decided { handler?(observation) }
    }

    /// Runs on `frameQueue` only.
    private func ownerMatches(_ pixels: CVPixelBuffer, face: VNFaceObservation, signature: FaceSignature) -> Bool {
        if recognizer == nil { recognizer = FaceRecognizer() }
        guard let recognizer, let aligned = vision.landmarks(of: face, in: pixels),
              let embedding = recognizer.embedding(of: pixels, face: aligned)
        else { return false }
        return FaceRecognizer.matches(embedding, signature)
    }

    // MARK: - Pure decisions, tested without a camera

    struct FaceMeasure: Equatable {
        var widthPx: Double
        var yawDegrees: Double?
        var pitchDegrees: Double?
    }

    static let maxYawDegrees = 30.0
    static let maxPitchDegrees = 25.0
    /// Shoulders are about 40 cm across and a face about 15 cm, so a body box is scaled to a face width
    /// and goes through the same pinhole maths (and the same calibration) as a face.
    static let faceToShouldersRatio = 15.0 / 40.0
    /// Reported when a person is seen but their size is unusable: far, but finite so traces still encode.
    static let farCm = 1000.0

    static func observation(
        face: FaceMeasure?, bodyWidthPx: Double?, imageWidthPx: Double, calibration: Calibration?,
        brightness: Double? = nil
    ) -> Observation {
        guard face != nil || bodyWidthPx != nil else {
            return Observation(source: .camera, person: false, brightness: brightness)
        }
        let faceEquivalentPx = face?.widthPx ?? (bodyWidthPx ?? 0) * faceToShouldersRatio
        let estimate = Distance.estimate(faceWidthPx: faceEquivalentPx, imageWidthPx: imageWidthPx, calibration: calibration)
        let distance = clamped(estimate)
        var facing: Bool?
        if let yaw = face?.yawDegrees, let pitch = face?.pitchDegrees {
            facing = abs(yaw) <= maxYawDegrees && abs(pitch) <= maxPitchDegrees
        }
        return Observation(source: .camera, person: true, distanceCm: distance, facingScreen: facing, brightness: brightness)
    }
}

/// One owner measurement: the sampled frame plus the next frames at the sensor rate (about 130 ms at
/// 15 fps). Three frames in a row must match, so one lucky frame of a stranger never counts as the owner.
struct OwnerCheck {
    static let frames = 3
    /// Beyond this the face is too small for a reliable embedding, so `owner` stays unknown.
    static let maxDistanceCm = 150.0
    /// A check whose frames stopped coming (mode change, camera stopped) is dropped, not delivered late.
    static let maxAge = 1.0

    var observation: Observation
    var started: Double
    private(set) var matched = 0

    init(observation: Observation, started: Double) {
        self.observation = observation
        self.started = started
    }

    static func wanted(for observation: Observation) -> Bool {
        guard observation.person, let distance = observation.distanceCm else { return false }
        return distance <= maxDistanceCm
    }

    func isStale(at now: Double) -> Bool { now - started > Self.maxAge }

    /// nil while more frames are needed. The first miss decides false at once, saving the rest.
    mutating func record(_ match: Bool) -> Bool? {
        guard match else { return false }
        matched += 1
        return matched >= Self.frames ? true : nil
    }
}

extension Calibration {
    static let defaultDistanceCm = 60.0
}

/// When to run Vision: at once when the scene moves (at most `motionInterval` apart), and on the mode's
/// slow interval when nothing moves, so someone sitting very still is still seen.
struct VisionSchedule {
    /// About 4 passes a second while something moves: a short wave is caught, and the cost stays bounded.
    static let motionInterval = 0.25

    /// A motion pass runs the body and hand passes too; a still pass only looks for a face and a body box.
    enum Pass: Equatable { case still, motion }

    private var slow: FrameThrottle
    private var fast: FrameThrottle
    /// Motion the cap or an owner check held back. The gate has already moved past those frames, so
    /// dropping it would lose a short wave; it runs on the first frame the cap allows instead.
    private var pendingMotion = false

    init(mode: SamplingMode) {
        slow = FrameThrottle(interval: FrameThrottle.interval(for: mode))
        fast = FrameThrottle(interval: mode == .off ? nil : Self.motionInterval)
    }

    /// nil when this frame is skipped.
    mutating func shouldRun(at now: Double, moved: Bool) -> Pass? {
        guard slow.interval != nil else { return nil }
        if moved || pendingMotion {
            guard fast.shouldSample(at: now) else {
                pendingMotion = true
                return nil
            }
            pendingMotion = false
            // A motion pass counts as the slow sample too, so a still scene waits a full interval after it.
            slow.mark(at: now)
            return .motion
        }
        guard slow.shouldSample(at: now) else { return nil }
        fast.mark(at: now)
        return .still
    }

    /// Motion seen on a frame that went to something else, such as an owner check.
    mutating func noteMotion() {
        if slow.interval != nil { pendingMotion = true }
    }
}

/// Lets one frame through per interval and drops the rest.
struct FrameThrottle {
    /// nil means no frames at all.
    var interval: Double?
    private var last: Double?

    init(interval: Double?) {
        self.interval = interval
    }

    static func interval(for mode: SamplingMode) -> Double? {
        switch mode {
        case .off: nil
        case .checking: 1
        case .watching: 2
        }
    }

    /// Frames arrive with jitter, so a frame a little early still counts; otherwise a camera running at
    /// exactly the sample rate would lose every other sample.
    static let earlyTolerance = 0.9

    mutating func shouldSample(at now: Double) -> Bool {
        guard let interval else { return false }
        if let last, now - last < interval * Self.earlyTolerance { return false }
        last = now
        return true
    }

    /// Records a frame taken for another reason, so the next one waits a full interval from it.
    mutating func mark(at now: Double) {
        last = now
    }
}

private final class FrameDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    // Unowned would crash if a late frame arrives during teardown; weak just drops it.
    private weak var owner: CameraSource?

    init(owner: CameraSource) {
        self.owner = owner
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        owner?.handle(sampleBuffer)
    }
}

/// The Vision requests and one sequence handler, reused for every frame.
private final class VisionPipeline {
    private let handler = VNSequenceRequestHandler()
    private let faces: VNDetectFaceRectanglesRequest = {
        // Revision 3 reports yaw and pitch from the rectangle pass alone, so landmarks are not needed.
        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision3
        return request
    }()
    private let bodies: VNDetectHumanRectanglesRequest = {
        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = true
        return request
    }()

    /// Built on first use and dropped after `poseIdleSeconds` without use, so a camera that always finds a
    /// face, or a still empty room, does not keep the pose requests and their own handler around.
    private var poses: PoseRequests?
    private var posesUsedAt = 0.0
    static let poseIdleSeconds = 30.0

    func bodyJoints(in pixels: CVPixelBuffer) -> BodyJoints? { usePoses().bodyJoints(in: pixels) }
    func handJoints(in pixels: CVPixelBuffer) -> [HandJoints] { usePoses().handJoints(in: pixels) }

    /// Called on every Vision pass.
    func dropIdlePoses() {
        if poses != nil, ProcessInfo.processInfo.systemUptime - posesUsedAt > Self.poseIdleSeconds { poses = nil }
    }

    private func usePoses() -> PoseRequests {
        posesUsedAt = ProcessInfo.processInfo.systemUptime
        if let poses { return poses }
        let made = PoseRequests()
        poses = made
        return made
    }

    /// Built on first use, so a Mac without an owner signature never loads the landmarks model.
    private lazy var landmarks = VNDetectFaceLandmarksRequest()

    func largestFace(in pixels: CVPixelBuffer, imageWidth: Double) -> (measure: CameraSource.FaceMeasure, observation: VNFaceObservation)? {
        guard (try? handler.perform([faces], on: pixels)) != nil,
              let face = faces.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width })
        else { return nil }
        let measure = CameraSource.FaceMeasure(
            widthPx: face.boundingBox.width * imageWidth,
            yawDegrees: face.yaw.map { $0.doubleValue * 180 / .pi },
            pitchDegrees: face.pitch.map { $0.doubleValue * 180 / .pi })
        return (measure, face)
    }

    /// Landmarks for one face already found, which the recogniser needs to align it.
    func landmarks(of face: VNFaceObservation, in pixels: CVPixelBuffer) -> VNFaceObservation? {
        landmarks.inputFaceObservations = [face]
        guard (try? handler.perform([landmarks], on: pixels)) != nil else { return nil }
        return landmarks.results?.first
    }

    /// The widest upper body as a share of the image width.
    func widestUpperBody(in pixels: CVPixelBuffer) -> Double? {
        guard (try? handler.perform([bodies], on: pixels)) != nil else { return nil }
        return bodies.results?.map { Double($0.boundingBox.width) }.max()
    }
}
