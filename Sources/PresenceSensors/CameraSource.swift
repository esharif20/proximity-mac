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
    }

    private let state = Mutex(State())
    private let sessionQueue = DispatchQueue(label: "camera.session")
    private let frameQueue = DispatchQueue(label: "camera.frames")
    private var session: AVCaptureSession?
    private lazy var delegate = FrameDelegate(owner: self)

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
        let running = state.withLock { s -> Bool in
            s.mode = mode
            if s.calibrationWidths == nil { s.throttle = FrameThrottle(interval: FrameThrottle.interval(for: mode)) }
            return mode != .off || s.calibrationWidths != nil
        }
        setRunning(running)
    }

    /// Samples about 3 s of frames while the person sits normally, then restores the previous mode.
    public func calibrate() async -> Calibration? {
        state.withLock { s in
            s.calibrationWidths = []
            s.throttle = FrameThrottle(interval: 0.1)
        }
        setRunning(true)
        try? await Task.sleep(for: .seconds(3))
        let (widths, mode) = state.withLock { s -> ([Double], SamplingMode) in
            defer {
                s.calibrationWidths = nil
                s.throttle = FrameThrottle(interval: FrameThrottle.interval(for: s.mode))
            }
            return (s.calibrationWidths ?? [], s.mode)
        }
        setRunning(mode != .off)
        return Distance.calibration(
            fromFaceWidths: widths, imageWidthPx: CameraSource.captureWidthPx, distanceCm: Calibration.defaultDistanceCm)
    }

    // MARK: - Capture

    /// The 640x480 preset is the lowest one Vision still finds faces with at desk distance.
    static let captureWidthPx = 640.0

    private func setRunning(_ running: Bool) {
        sessionQueue.async { [self] in
            if running {
                if session == nil { session = makeSession() }
                if let session, !session.isRunning { session.startRunning() }
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
        session.sessionPreset = session.canSetSessionPreset(.vga640x480) ? .vga640x480 : .low
        guard session.canAddInput(input) else { return nil }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(delegate, queue: frameQueue)
        guard session.canAddOutput(output) else { return nil }
        session.addOutput(output)
        session.commitConfiguration()
        Self.useLowestFrameRate(device)
        return session
    }

    /// Fewer frames from the sensor means less power, even though most are dropped anyway.
    private static func useLowestFrameRate(_ device: AVCaptureDevice) {
        guard let slowest = device.activeFormat.videoSupportedFrameRateRanges.min(by: { $0.minFrameRate < $1.minFrameRate }),
              (try? device.lockForConfiguration()) != nil
        else { return }
        device.activeVideoMinFrameDuration = slowest.maxFrameDuration
        device.activeVideoMaxFrameDuration = slowest.maxFrameDuration
        device.unlockForConfiguration()
    }

    // MARK: - Frames

    fileprivate func handle(_ sampleBuffer: CMSampleBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        let (take, calibrating) = state.withLock { s in (s.throttle.shouldSample(at: now), s.calibrationWidths != nil) }
        guard take, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let imageWidth = Double(CVPixelBufferGetWidth(pixels))

        let faces = VNDetectFaceLandmarksRequest()
        let bodies = VNDetectHumanRectanglesRequest()
        bodies.upperBodyOnly = true
        let requests: [VNRequest] = calibrating ? [faces] : [faces, bodies]
        guard (try? VNImageRequestHandler(cvPixelBuffer: pixels, options: [:]).perform(requests)) != nil else { return }

        let face = faces.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }).map {
            FaceMeasure(
                widthPx: $0.boundingBox.width * imageWidth,
                yawDegrees: $0.yaw.map { $0.doubleValue * 180 / .pi },
                pitchDegrees: $0.pitch.map { $0.doubleValue * 180 / .pi })
        }
        if calibrating {
            if let face { state.withLock { $0.calibrationWidths?.append(face.widthPx * Self.captureWidthPx / imageWidth) } }
            return
        }
        let bodyWidth = bodies.results?.map(\.boundingBox.width).max().map { $0 * imageWidth }
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

    mutating func shouldSample(at now: Double) -> Bool {
        guard let interval else { return false }
        if let last, now - last < interval { return false }
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
