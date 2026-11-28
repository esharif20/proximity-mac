@preconcurrency import AVFoundation
import CoreImage
import Foundation
import Synchronization
import Vision

/// One analysed camera frame for the Setup window.
///
/// Points and boxes are normalised 0...1 with the origin at the top left, mirrored like a selfie view so
/// they line up with `image`, which is mirrored the same way.
public struct LabFrame: Sendable {
    /// For the preview only. It lives in memory and is never written anywhere.
    public var image: CGImage
    public var face: LabFace?
    public var hands: [LabHand]
    public var body: CGRect?
    /// Time spent in Vision for this frame.
    public var visionMs: Double
    /// Frames analysed per second, smoothed.
    public var fps: Double
}

public struct LabFace: Sendable {
    public var box: CGRect
    public var landmarks: [CGPoint]
    /// Yaw and roll are flipped to match the mirrored view; pitch is unchanged by a mirror.
    public var yawDeg, pitchDeg, rollDeg, distanceCm, horizontalAngleDeg: Double
}

public struct LabHand: Sendable {
    /// Always 21 joints in `LabGeometry.handJoints` order. A joint Vision could not see is NaN.
    public var joints: [CGPoint]
    /// The person's own left hand, whatever side of the mirrored view it shows on.
    public var isLeft: Bool
}

/// The live vision engine behind Setup: face landmarks and pose, hands, upper body and distance on
/// every frame the analysis keeps up with. It runs only while Setup shows it; the app turns the
/// presence camera off first, since only one capture session may run at a time.
///
/// Frames, crops and embeddings stay in memory and are never written to disk or a log.
///
/// `@unchecked Sendable`: the capture session is touched only on `sessionQueue`, the Vision pipeline
/// only on `analysisQueue`, and every other piece of state is behind `state`.
public final class VisionLab: @unchecked Sendable {
    private struct State {
        var running = false
        var handler: (@Sendable (LabFrame) -> Void)?
        var calibration: Calibration?
        var rate = FrameRate()
        /// Face widths in pixels and the image width, collected while `calibrate` runs; nil otherwise.
        var calibrationWidths: [Double]?
        var calibrationImageWidth: Double = 0
        var calibrationStart: Double?
        var enrolment: Enrolment?
    }

    private struct Enrolment {
        var filter = EnrolmentFilter()
        var embeddings: [[Float]] = []
        var target: Int
        var progress: @Sendable (Int) -> Void
        var done: Bool { embeddings.count >= target }
    }

    private let state = Mutex(State())
    private let busy = BusyGate()
    private let sessionQueue = DispatchQueue(label: "visionlab.session")
    private let captureQueue = DispatchQueue(label: "visionlab.capture")
    private let analysisQueue = DispatchQueue(label: "visionlab.analysis", qos: .userInitiated)
    private var session: AVCaptureSession?
    private lazy var delegate = LabFrameDelegate(owner: self)
    /// Built once and used only on `analysisQueue`: Vision reloads its models when requests are rebuilt.
    private lazy var pipeline = LabPipeline()

    /// Gives up if the camera delivers nothing for this long (no camera, or permission denied).
    static let firstFrameTimeout = 8.0
    /// Enrolment ends without a signature if it cannot collect its samples in this long.
    static let enrolmentTimeout = 45.0

    public init() {}

    deinit {
        // A running session holds the camera on by itself, so the light would stay on.
        if let session { session.stopRunning() }
    }

    /// The person's saved calibration, used for `LabFace.distanceCm`.
    public var calibration: Calibration? {
        get { state.withLock { $0.calibration } }
        set { state.withLock { $0.calibration = newValue } }
    }

    public func start(_ onFrame: @escaping @Sendable (LabFrame) -> Void) {
        state.withLock { s in
            s.handler = onFrame
            s.running = true
            s.rate = FrameRate()
        }
        reconcile()
    }

    /// Returns once the camera is released, so the presence camera can take it over straight after.
    public func stop() {
        state.withLock { s in
            s.running = false
            s.handler = nil
        }
        reconcile(wait: true)
    }

    /// Whether a capture session exists, read on `sessionQueue` so it reflects every queued change.
    var hasSession: Bool { sessionQueue.sync { session != nil } }

    /// Samples `seconds` of face widths, counted from the first frame after the call, and turns them into
    /// a calibration at the default sitting distance. Nil when the lab is not running or the face moved.
    public func calibrate(seconds: Double = 3) async -> Calibration? {
        state.withLock { s in
            s.calibrationWidths = []
            s.calibrationStart = nil
        }
        let began = ProcessInfo.processInfo.systemUptime
        while !Task.isCancelled, state.withLock({ $0.running }) {
            let now = ProcessInfo.processInfo.systemUptime
            let start = state.withLock { $0.calibrationStart }
            if let start, now - start >= seconds { break }
            if start == nil, now - began >= Self.firstFrameTimeout { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let (widths, imageWidth) = state.withLock { s -> ([Double], Double) in
            defer {
                s.calibrationWidths = nil
                s.calibrationStart = nil
            }
            return (s.calibrationWidths ?? [], s.calibrationImageWidth)
        }
        let result = Distance.calibration(
            fromFaceWidths: widths, imageWidthPx: imageWidth, distanceCm: Calibration.defaultDistanceCm)
        if let result { calibration = result }
        return result
    }

    /// Collects `samples` face embeddings from sharp, roughly frontal frames, each in a pose not already
    /// taken, and builds the owner's signature from them. Nil when the lab stops or time runs out.
    public func enrolOwner(samples: Int = 20, progress: @escaping @Sendable (Int) -> Void) async -> FaceSignature? {
        state.withLock { $0.enrolment = Enrolment(target: max(1, samples), progress: progress) }
        let began = ProcessInfo.processInfo.systemUptime
        while !Task.isCancelled, state.withLock({ $0.running && !($0.enrolment?.done ?? true) }),
              ProcessInfo.processInfo.systemUptime - began < Self.enrolmentTimeout {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let enrolment = state.withLock { s -> Enrolment? in
            defer { s.enrolment = nil }
            return s.enrolment
        }
        guard let enrolment, enrolment.done else { return nil }
        return FaceRecognizer.signature(from: enrolment.embeddings)
    }

    // MARK: - Capture

    private func reconcile(wait: Bool = false) {
        let apply = { [self] in
            let running = state.withLock { $0.running }
            if running {
                if session == nil { session = makeSession() }
                if let session, !session.isRunning { session.startRunning() }
            } else if let session {
                session.stopRunning()
                self.session = nil
            }
        }
        if wait { sessionQueue.sync(execute: apply) } else { sessionQueue.async(execute: apply) }
    }

    private func makeSession() -> AVCaptureSession? {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device)
        else { return nil }
        let session = AVCaptureSession()
        session.beginConfiguration()
        guard session.canAddInput(input) else { return nil }
        session.addInput(input)
        // 4:3 like CameraSource: its 640x480 covers the same field as any 4:3 format, so a calibration
        // made here gives the same distances there. A 16:9 frame is wider and would skew them.
        let sizes = device.formats.map { format -> (width: Int, height: Int) in
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return (Int(size.width), Int(size.height))
        }
        if let index = Self.captureFormatIndex(sizes), (try? device.lockForConfiguration()) != nil {
            device.activeFormat = device.formats[index]
            let ranges = device.activeFormat.videoSupportedFrameRateRanges.map { (min: $0.minFrameRate, max: $0.maxFrameRate) }
            if let fps = Self.frameRate(ranges: ranges) {
                device.activeVideoMinFrameDuration = CMTime(value: 1000, timescale: CMTimeScale((fps.max * 1000).rounded()))
                device.activeVideoMaxFrameDuration = CMTime(value: 1000, timescale: CMTimeScale((fps.min * 1000).rounded()))
            }
            device.unlockForConfiguration()
        } else {
            session.sessionPreset = .vga640x480
        }
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(delegate, queue: captureQueue)
        guard session.canAddOutput(output) else { return nil }
        session.addOutput(output)
        session.commitConfiguration()
        return session
    }

    static let maxCaptureWidth = 1280
    static let wantedFps = 15.0...30.0

    /// The largest 4:3 format no wider than 1280, or nil to fall back to the 640x480 preset.
    static func captureFormatIndex(_ formats: [(width: Int, height: Int)]) -> Int? {
        formats.indices
            .filter { formats[$0].width * 3 == formats[$0].height * 4 && formats[$0].width <= maxCaptureWidth }
            .max { formats[$0].width < formats[$1].width }
    }

    /// The part of 15 to 30 fps the format supports, preferring the range that reaches highest.
    static func frameRate(ranges: [(min: Double, max: Double)]) -> (min: Double, max: Double)? {
        ranges
            .map { (min: Swift.max($0.min, wantedFps.lowerBound), max: Swift.min($0.max, wantedFps.upperBound)) }
            .filter { $0.min <= $0.max }
            .max { $0.max < $1.max }
    }

    // MARK: - Frames

    /// Runs on `captureQueue`. A frame that arrives while the last one is still in Vision is dropped,
    /// so the preview stays live instead of falling behind.
    fileprivate func receive(_ sampleBuffer: CMSampleBuffer) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer), busy.tryEnter() else { return }
        nonisolated(unsafe) let frame = pixels
        analysisQueue.async { [self] in
            defer { busy.leave() }
            analyse(frame)
        }
    }

    private func analyse(_ pixels: CVPixelBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        let (running, calibration, enrolling) = state.withLock { ($0.running, $0.calibration, $0.enrolment.map { !$0.done } ?? false) }
        guard running else { return }
        let imageWidth = Double(CVPixelBufferGetWidth(pixels))
        let began = ProcessInfo.processInfo.systemUptime
        guard let result = pipeline.analyse(pixels, calibration: calibration, quality: enrolling) else { return }
        let visionMs = (ProcessInfo.processInfo.systemUptime - began) * 1000

        if enrolling, let face = result.face, let observation = result.faceObservation,
           let quality = result.faceQuality {
            enrol(pixels, observation: observation, yaw: face.yawDeg, pitch: face.pitchDeg, quality: quality)
        }
        let (handler, fps) = state.withLock { s -> ((@Sendable (LabFrame) -> Void)?, Double) in
            if let widths = s.calibrationWidths {
                if s.calibrationStart == nil { s.calibrationStart = now }
                if let face = result.face {
                    s.calibrationWidths = widths + [face.box.width * imageWidth]
                    s.calibrationImageWidth = imageWidth
                }
            }
            return (s.handler, s.rate.tick(at: now))
        }
        handler?(LabFrame(
            image: result.image, face: result.face, hands: result.hands, body: result.body,
            visionMs: visionMs, fps: fps))
    }

    private func enrol(_ pixels: CVPixelBuffer, observation: VNFaceObservation, yaw: Double, pitch: Double, quality: Float) {
        let candidate = state.withLock { s -> Bool in
            guard let enrolment = s.enrolment, !enrolment.done else { return false }
            return enrolment.filter.isCandidate(yawDeg: yaw, pitchDeg: pitch, quality: quality)
        }
        // The embedding runs outside the lock: it is a model call of several milliseconds. The pose is
        // recorded only once it succeeds, so a failed embedding does not block that pose for good.
        guard candidate, let embedding = pipeline.recognizer.embedding(of: pixels, face: observation) else { return }
        let report = state.withLock { s -> (@Sendable (Int) -> Void, Int)? in
            guard s.enrolment != nil, !(s.enrolment?.done ?? true) else { return nil }
            s.enrolment?.filter.record(yawDeg: yaw, pitchDeg: pitch)
            s.enrolment?.embeddings.append(embedding)
            return s.enrolment.map { ($0.progress, $0.embeddings.count) }
        }
        if let (progress, count) = report { progress(count) }
    }
}

// MARK: - Pure pieces, tested without a camera

/// Vision's normalised space (origin bottom left, camera's own view) to the lab's (origin top left,
/// mirrored like a selfie).
enum LabGeometry {
    /// Typical built-in MacBook camera field of view, as `Distance` assumes.
    static let horizontalFieldOfViewDegrees = 70.0

    static func mirrored(_ point: CGPoint) -> CGPoint {
        CGPoint(x: 1 - point.x, y: 1 - point.y)
    }

    static func mirrored(_ rect: CGRect) -> CGRect {
        CGRect(x: 1 - rect.maxX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
    }

    /// A landmark point, given by Vision relative to the face box, in the mirrored image.
    static func landmark(_ point: CGPoint, in box: CGRect) -> CGPoint {
        mirrored(CGPoint(x: box.minX + point.x * box.width, y: box.minY + point.y * box.height))
    }

    /// Degrees left (negative) or right (positive) of the camera axis, as seen in the mirrored view,
    /// for a point at mirrored x. Pinhole maths: the image edge is half the field of view.
    static func horizontalAngle(mirroredX x: Double) -> Double {
        let halfFov = horizontalFieldOfViewDegrees / 2 * .pi / 180
        return atan((x - 0.5) * 2 * tan(halfFov)) * 180 / .pi
    }

    static let handJoints: [VNHumanHandPoseObservation.JointName] = [
        .wrist,
        .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
        .indexMCP, .indexPIP, .indexDIP, .indexTip,
        .middleMCP, .middlePIP, .middleDIP, .middleTip,
        .ringMCP, .ringPIP, .ringDIP, .ringTip,
        .littleMCP, .littlePIP, .littleDIP, .littleTip,
    ]

    static let missingJoint = CGPoint(x: Double.nan, y: .nan)
}

/// Lets one frame into analysis at a time; frames that arrive meanwhile are dropped.
final class BusyGate: Sendable {
    private let busy = Mutex(false)

    func tryEnter() -> Bool {
        busy.withLock { busy in
            if busy { return false }
            busy = true
            return true
        }
    }

    func leave() {
        busy.withLock { $0 = false }
    }
}

/// Analysed frames per second, smoothed so the readout does not flicker.
struct FrameRate {
    private(set) var fps = 0.0
    private var last: Double?
    static let smoothing = 0.1

    mutating func tick(at now: Double) -> Double {
        defer { last = now }
        guard let last, now > last else { return fps }
        let instant = 1 / (now - last)
        fps = fps == 0 ? instant : fps + (instant - fps) * Self.smoothing
        return fps
    }
}

/// Picks the frames worth an embedding: sharp, frontal enough, and a pose the signature lacks, so 20
/// samples cover the face from a spread of angles instead of 20 copies of one.
struct EnrolmentFilter {
    static let maxYawDegrees = 35.0
    /// Vision's face capture quality is relative; below this the frame is blurred or badly lit.
    static let minQuality: Float = 0.3
    /// A pose within this many degrees of a kept one, in both yaw and pitch, is a near-duplicate.
    static let minPoseSpreadDegrees = 3.0

    private(set) var poses: [(yaw: Double, pitch: Double)] = []

    /// Whether a frame is worth an embedding. Records nothing: call `record` once the embedding exists.
    func isCandidate(yawDeg: Double, pitchDeg: Double, quality: Float) -> Bool {
        guard abs(yawDeg) < Self.maxYawDegrees, quality >= Self.minQuality else { return false }
        return !poses.contains {
            abs($0.yaw - yawDeg) < Self.minPoseSpreadDegrees && abs($0.pitch - pitchDeg) < Self.minPoseSpreadDegrees
        }
    }

    mutating func record(yawDeg: Double, pitchDeg: Double) {
        poses.append((yawDeg, pitchDeg))
    }

    /// `isCandidate` then `record`, for a sample whose embedding is already known to succeed.
    mutating func accept(yawDeg: Double, pitchDeg: Double, quality: Float) -> Bool {
        guard isCandidate(yawDeg: yawDeg, pitchDeg: pitchDeg, quality: quality) else { return false }
        record(yawDeg: yawDeg, pitchDeg: pitchDeg)
        return true
    }
}

// MARK: - Vision

private final class LabFrameDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    // Weak, not unowned: a late frame during teardown is dropped instead of crashing.
    private weak var owner: VisionLab?

    init(owner: VisionLab) {
        self.owner = owner
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        owner?.receive(sampleBuffer)
    }
}

private struct LabAnalysis {
    var image: CGImage
    var face: LabFace?
    var faceObservation: VNFaceObservation?
    var faceQuality: Float?
    var hands: [LabHand]
    var body: CGRect?
}

/// The Vision requests, reused for every frame on the analysis queue.
private final class LabPipeline {
    let recognizer = FaceRecognizer()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let faces: VNDetectFaceLandmarksRequest = {
        let request = VNDetectFaceLandmarksRequest()
        request.revision = VNDetectFaceLandmarksRequestRevision3
        return request
    }()
    private let hands: VNDetectHumanHandPoseRequest = {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        return request
    }()
    private let bodies: VNDetectHumanRectanglesRequest = {
        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = true
        return request
    }()
    private let quality = VNDetectFaceCaptureQualityRequest()

    static let minJointConfidence: Float = 0.3

    func analyse(_ pixels: CVPixelBuffer, calibration: Calibration?, quality wantsQuality: Bool) -> LabAnalysis? {
        let width = Double(CVPixelBufferGetWidth(pixels))
        let mirroredImage = CIImage(cvPixelBuffer: pixels).oriented(.upMirrored)
        guard let image = context.createCGImage(mirroredImage, from: mirroredImage.extent) else { return nil }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixels)
        guard (try? handler.perform([faces, hands, bodies])) != nil else {
            return LabAnalysis(image: image, hands: [])
        }

        let observation = faces.results?.max { $0.boundingBox.width < $1.boundingBox.width }
        let face = observation.map { labFace($0, imageWidth: width, calibration: calibration) }
        var faceQuality: Float?
        if wantsQuality, let observation {
            quality.inputFaceObservations = [observation]
            if (try? handler.perform([quality])) != nil {
                faceQuality = quality.results?.first?.faceCaptureQuality
            }
        }
        let labHands = (hands.results ?? []).map(labHand)
        let body = bodies.results?.max { $0.boundingBox.width < $1.boundingBox.width }
            .map { LabGeometry.mirrored($0.boundingBox) }
        return LabAnalysis(
            image: image, face: face, faceObservation: observation, faceQuality: faceQuality,
            hands: labHands, body: body)
    }

    private func labFace(_ face: VNFaceObservation, imageWidth: Double, calibration: Calibration?) -> LabFace {
        let box = face.boundingBox
        let mirroredBox = LabGeometry.mirrored(box)
        let points = face.landmarks?.allPoints?.normalizedPoints ?? []
        let distance = Distance.estimate(
            faceWidthPx: box.width * imageWidth, imageWidthPx: imageWidth, calibration: calibration)
        func degrees(_ radians: NSNumber?) -> Double { (radians?.doubleValue ?? 0) * 180 / .pi }
        return LabFace(
            box: mirroredBox,
            landmarks: points.map { LabGeometry.landmark($0, in: box) },
            yawDeg: -degrees(face.yaw),
            pitchDeg: degrees(face.pitch),
            rollDeg: -degrees(face.roll),
            distanceCm: distance.isFinite ? distance : 0,
            horizontalAngleDeg: LabGeometry.horizontalAngle(mirroredX: mirroredBox.midX))
    }

    private func labHand(_ hand: VNHumanHandPoseObservation) -> LabHand {
        let points = (try? hand.recognizedPoints(.all)) ?? [:]
        let joints = LabGeometry.handJoints.map { name -> CGPoint in
            guard let point = points[name], point.confidence >= Self.minJointConfidence else {
                return LabGeometry.missingJoint
            }
            return LabGeometry.mirrored(point.location)
        }
        return LabHand(joints: joints, isLeft: hand.chirality == .left)
    }
}
