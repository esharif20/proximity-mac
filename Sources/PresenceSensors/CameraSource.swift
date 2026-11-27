@preconcurrency import AVFoundation
import Foundation
import Synchronization
import Vision

/// The camera as a presence source: a low-resolution capture that runs only while sampling, with Vision
/// face landmarks and upper-body detection on about one frame a second or less.
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
        var handler: (@Sendable (Observation) -> Void)?
        var calibration: Calibration?
        /// Face widths collected while `calibrate()` runs; nil otherwise.
        var calibrationWidths: [Double]?
        /// When calibration saw its first frame, so its 3 s window excludes camera warm-up.
        var calibrationStart: Double?

        var wantsCamera: Bool { mode != .off || calibrationWidths != nil }
    }

    private let state = Mutex(State())
    private let sessionQueue = DispatchQueue(label: "camera.session")
    private let frameQueue = DispatchQueue(label: "camera.frames")
    private var session: AVCaptureSession?
    private lazy var delegate = FrameDelegate(owner: self)
    /// Built once and used only on `frameQueue`: rebuilding Vision requests per frame reloads their models.
    private lazy var vision = VisionPipeline()

    public init() {}

    /// The person's calibration, set by the Coordinator from Settings.
    public var calibration: Calibration? {
        get { state.withLock { $0.calibration } }
        set { state.withLock { $0.calibration = newValue } }
    }

    public func onObservation(_ handler: @escaping @Sendable (Observation) -> Void) {
        state.withLock { $0.handler = handler }
    }

    public func setMode(_ mode: SamplingMode) {
        state.withLock { s in
            s.mode = mode
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
            let (running, calibrating) = state.withLock { ($0.wantsCamera, $0.calibrationWidths != nil) }
            if running {
                if session == nil { session = makeSession() }
                guard let session else { return }
                if let device = (session.inputs.first as? AVCaptureDeviceInput)?.device {
                    Self.setFrameRate(device, calibrating: calibrating)
                }
                if !session.isRunning { session.startRunning() }
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

    private static func setFrameRate(_ device: AVCaptureDevice, calibrating: Bool) {
        let ranges = device.activeFormat.videoSupportedFrameRateRanges.map { (min: $0.minFrameRate, max: $0.maxFrameRate) }
        guard let fps = sensorFrameRate(ranges: ranges, calibrating: calibrating),
              (try? device.lockForConfiguration()) != nil
        else { return }
        let duration = CMTime(value: 1000, timescale: CMTimeScale((fps * 1000).rounded()))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        device.unlockForConfiguration()
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

    fileprivate func handle(_ sampleBuffer: CMSampleBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        let (take, calibrating) = state.withLock { s in
            if s.calibrationWidths != nil, s.calibrationStart == nil { s.calibrationStart = now }
            return (s.throttle.shouldSample(at: now), s.calibrationWidths != nil)
        }
        guard take, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let imageWidth = Double(CVPixelBufferGetWidth(pixels))

        guard let face = vision.largestFace(in: pixels, imageWidth: imageWidth) else {
            if calibrating { return }
            // Bodies only when there is no face: a face already answers "person" and gives a better distance.
            let bodyWidth = vision.widestUpperBody(in: pixels).map { $0 * imageWidth }
            let (handler, calibration) = state.withLock { ($0.handler, $0.calibration) }
            handler?(Self.observation(face: nil, bodyWidthPx: bodyWidth, imageWidthPx: imageWidth, calibration: calibration))
            return
        }
        if calibrating {
            state.withLock { $0.calibrationWidths?.append(face.widthPx * Self.captureWidthPx / imageWidth) }
            return
        }
        let bodyWidth: Double? = nil
        let (handler, calibration) = state.withLock { ($0.handler, $0.calibration) }
        handler?(Self.observation(face: face, bodyWidthPx: bodyWidth, imageWidthPx: imageWidth, calibration: calibration))
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
        face: FaceMeasure?, bodyWidthPx: Double?, imageWidthPx: Double, calibration: Calibration?
    ) -> Observation {
        guard face != nil || bodyWidthPx != nil else {
            return Observation(source: .camera, person: false)
        }
        let faceEquivalentPx = face?.widthPx ?? (bodyWidthPx ?? 0) * faceToShouldersRatio
        let estimate = Distance.estimate(faceWidthPx: faceEquivalentPx, imageWidthPx: imageWidthPx, calibration: calibration)
        let distance = estimate.isFinite ? min(max(estimate, 0), farCm) : farCm
        var facing: Bool?
        if let yaw = face?.yawDegrees, let pitch = face?.pitchDegrees {
            facing = abs(yaw) <= maxYawDegrees && abs(pitch) <= maxPitchDegrees
        }
        return Observation(source: .camera, person: true, distanceCm: distance, facingScreen: facing)
    }
}

extension Calibration {
    static let defaultDistanceCm = 60.0
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

/// The two Vision requests and one sequence handler, reused for every frame.
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

    func largestFace(in pixels: CVPixelBuffer, imageWidth: Double) -> CameraSource.FaceMeasure? {
        guard (try? handler.perform([faces], on: pixels)) != nil,
              let face = faces.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width })
        else { return nil }
        return CameraSource.FaceMeasure(
            widthPx: face.boundingBox.width * imageWidth,
            yawDegrees: face.yaw.map { $0.doubleValue * 180 / .pi },
            pitchDegrees: face.pitch.map { $0.doubleValue * 180 / .pi })
    }

    /// The widest upper body as a share of the image width.
    func widestUpperBody(in pixels: CVPixelBuffer) -> Double? {
        guard (try? handler.perform([bodies], on: pixels)) != nil else { return nil }
        return bodies.results?.map { Double($0.boundingBox.width) }.max()
    }
}
