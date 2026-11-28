import CoreGraphics
import CoreVideo
import Foundation
import Vision

/// The body pose joints that say a person is there, in pixels.
struct BodyJoints: Equatable, Sendable {
    var nose: CGPoint?
    var neck: CGPoint?
    var leftShoulder: CGPoint?
    var rightShoulder: CGPoint?

    /// Both shoulders plus the neck or the nose: enough for a person whose head is above the frame, which is
    /// what standing at a desk looks like to a camera angled for someone seated. nil when that is not seen.
    var shoulderWidthPx: Double? {
        guard let left = leftShoulder, let right = rightShoulder, neck != nil || nose != nil else { return nil }
        return Double(hypot(right.x - left.x, right.y - left.y))
    }
}

/// What person segmentation saw: how much of the frame is person, and how far down it reaches.
struct PersonMask: Equatable, Sendable {
    /// Mask values at or above this (confidence 0.5) are person pixels.
    static let personValue: UInt8 = 128

    /// 0 to 1.
    var share: Double
    /// The lowest person row, 0 at the top of the frame and 1 at the bottom; nil for an empty mask.
    var lowest: Double?

    init(share: Double, lowest: Double?) {
        self.share = share
        self.lowest = lowest
    }

    /// From row-major mask values, top row first, as a OneComponent8 buffer stores them.
    init(values: [UInt8], width: Int, height: Int) {
        self.init(width: width, height: height) { row, col in values[row * width + col] }
    }

    /// nil for a buffer that is not a one-byte mask.
    init?(pixels: CVPixelBuffer) {
        guard CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_OneComponent8,
              CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess
        else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        guard let base = CVPixelBufferGetBaseAddress(pixels)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        self.init(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels)) { row, col in
            base[row * stride + col]
        }
    }

    private init(width: Int, height: Int, value: (Int, Int) -> UInt8) {
        guard width > 0, height > 0 else {
            self.init(share: 0, lowest: nil)
            return
        }
        var covered = 0, lowestRow: Int?
        for row in 0..<height {
            var inRow = 0
            for col in 0..<width where value(row, col) >= Self.personValue { inRow += 1 }
            if inRow > 0 { lowestRow = row }
            covered += inRow
        }
        self.init(share: Double(covered) / Double(width * height), lowest: lowestRow.map { Double($0 + 1) / Double(height) })
    }
}

/// One hand from hand pose, in pixels.
struct HandJoints: Equatable, Sendable {
    var wrist: CGPoint
    var middleKnuckle: CGPoint

    var lengthPx: Double { Double(hypot(middleKnuckle.x - wrist.x, middleKnuckle.y - wrist.y)) }
}

extension CameraSource {
    /// Beyond this a hand is a few pixels long and hand pose guesses, so it is not counted at all.
    static let maxHandDistanceCm = 150.0

    /// A person from body pose, or nil when the joints are not enough to say so.
    static func observation(
        body: BodyJoints, imageWidthPx: Double, calibration: Calibration?, brightness: Double? = nil
    ) -> Observation? {
        guard let shoulders = body.shoulderWidthPx else { return nil }
        let estimate = Distance.estimate(shoulderWidthPx: shoulders, imageWidthPx: imageWidthPx, calibration: calibration)
        return Observation(source: .camera, person: true, distanceCm: clamped(estimate), brightness: brightness)
    }

    /// The nearest hand as a person close, or nil when no hand is inside the Desk radius (and the 150 cm
    /// floor). `owner` stays nil: a hand does not say whose it is, so with "Only wake for me" on the engine
    /// does not wake for it.
    static func observation(
        hands: [HandJoints], imageWidthPx: Double, calibration: Calibration?, deskRadiusCm: Double = maxHandDistanceCm,
        brightness: Double? = nil
    ) -> Observation? {
        guard let longest = hands.map(\.lengthPx).max() else { return nil }
        let estimate = Distance.estimate(handLengthPx: longest, imageWidthPx: imageWidthPx, calibration: calibration)
        guard estimate.isFinite, estimate <= min(maxHandDistanceCm, deskRadiusCm) else { return nil }
        return Observation(source: .camera, person: true, distanceCm: clamped(estimate), brightness: brightness)
    }

    /// Below this share the mask is noise or a sliver at the edge, so it says nothing and the fallbacks run.
    static let minPersonShare = 0.005
    /// A person seated at the desk reaches the bottom of the frame. One whose lowest pixel is above this
    /// line is standing back or walking past, so they never count as closer than `maxHandDistanceCm`.
    static let seatedLowest = 0.8

    /// A person from segmentation, close or far by the share of the frame they cover, or nil for an empty mask.
    static func observation(mask: PersonMask, brightness: Double? = nil) -> Observation? {
        guard mask.share >= minPersonShare, let lowest = mask.lowest else { return nil }
        var estimate = Distance.estimate(personShare: mask.share)
        if lowest < seatedLowest { estimate = max(estimate, maxHandDistanceCm) }
        return Observation(source: .camera, person: true, distanceCm: clamped(estimate), brightness: brightness)
    }

    /// The passes tried when no face is found, run lazily so a pass that answers saves the rest.
    struct FacelessPasses {
        /// Person segmentation: sees a person however they face, so it answers first.
        var mask: () -> PersonMask? = { nil }
        var body: () -> BodyJoints?
        /// The widest upper-body box, in pixels.
        var box: () -> Double?
        var hands: () -> [HandJoints]
    }

    /// Segmentation first, on every pass: presence must not depend on a face or on movement. Then body
    /// pose, since it sees a torso with the head above the frame; then the upper-body box; hands
    /// last, so a person already seen far away is never turned into a close one by a stray hand. Body and
    /// hand pose run on motion passes only (`fullChain`): segmentation already sees someone still at the desk
    /// looking down at a phone, and running both poses on every Checking pass costs about 23 ms a second in an
    /// empty room (docs/spikes/camera-cost.md).
    static func observationWithoutFace(
        fullChain: Bool, passes: FacelessPasses, imageWidthPx: Double, calibration: Calibration?, deskRadiusCm: Double,
        brightness: Double?
    ) -> Observation {
        if let mask = passes.mask(), let seen = observation(mask: mask, brightness: brightness) {
            return seen
        }
        if fullChain, let body = passes.body(),
           let seen = observation(body: body, imageWidthPx: imageWidthPx, calibration: calibration, brightness: brightness) {
            return seen
        }
        if let box = passes.box() {
            return observation(face: nil, bodyWidthPx: box, imageWidthPx: imageWidthPx, calibration: calibration, brightness: brightness)
        }
        if fullChain, let hand = observation(
            hands: passes.hands(), imageWidthPx: imageWidthPx, calibration: calibration, deskRadiusCm: deskRadiusCm,
            brightness: brightness) {
            return hand
        }
        return Observation(source: .camera, person: false, brightness: brightness)
    }

    /// Finite and never negative, so traces still encode.
    static func clamped(_ estimate: Double) -> Double {
        estimate.isFinite ? min(max(estimate, 0), farCm) : farCm
    }
}

/// When the pose requests may be dropped: after `idleSeconds` without use, or as soon as the camera stops.
struct PoseLifetime {
    static let idleSeconds = 30.0
    private var usedAt: Double?

    mutating func used(at now: Double) {
        usedAt = now
    }

    mutating func shouldDrop(at now: Double, cameraStopped: Bool) -> Bool {
        guard let usedAt, cameraStopped || now - usedAt > Self.idleSeconds else { return false }
        self.usedAt = nil
        return true
    }
}

/// Person segmentation, built when the camera starts sampling and dropped when it stops.
final class PersonSegmentation {
    private let handler = VNSequenceRequestHandler()
    private let request: VNGeneratePersonSegmentationRequest = {
        let request = VNGeneratePersonSegmentationRequest()
        // .fast gives the smallest mask and the lowest cost; the share of the frame needs no fine edges.
        request.qualityLevel = .fast
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return request
    }()

    func mask(in pixels: CVPixelBuffer) -> PersonMask? {
        guard (try? handler.perform([request], on: pixels)) != nil,
              let result = request.results?.first
        else { return nil }
        return PersonMask(pixels: result.pixelBuffer)
    }
}

/// The body pose and hand pose requests, built once and used only on the camera's frame queue.
final class PoseRequests {
    /// Joints below this confidence are treated as not seen.
    static let minConfidence: Float = 0.3

    /// Its own handler, so dropping this object drops everything the pose passes hold.
    private let handler = VNSequenceRequestHandler()
    private let body = VNDetectHumanBodyPoseRequest()
    private let hands: VNDetectHumanHandPoseRequest = {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        return request
    }()

    /// The widest-shouldered body's joints, or nil when no body shows enough of itself.
    func bodyJoints(in pixels: CVPixelBuffer) -> BodyJoints? {
        guard (try? handler.perform([body], on: pixels)) != nil, let results = body.results else { return nil }
        let size = Self.size(of: pixels)
        return results
            .map { pose in
                func joint(_ name: VNHumanBodyPoseObservation.JointName) -> CGPoint? {
                    Self.scaled(try? pose.recognizedPoint(name), size)
                }
                return BodyJoints(
                    nose: joint(.nose), neck: joint(.neck), leftShoulder: joint(.leftShoulder), rightShoulder: joint(.rightShoulder))
            }
            .filter { $0.shoulderWidthPx != nil }
            .max { ($0.shoulderWidthPx ?? 0) < ($1.shoulderWidthPx ?? 0) }
    }

    func handJoints(in pixels: CVPixelBuffer) -> [HandJoints] {
        guard (try? handler.perform([hands], on: pixels)) != nil, let results = hands.results else { return [] }
        let size = Self.size(of: pixels)
        return results.compactMap { pose in
            guard let wrist = Self.scaled(try? pose.recognizedPoint(.wrist), size),
                  let knuckle = Self.scaled(try? pose.recognizedPoint(.middleMCP), size)
            else { return nil }
            return HandJoints(wrist: wrist, middleKnuckle: knuckle)
        }
    }

    private static func size(of pixels: CVPixelBuffer) -> CGSize {
        CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
    }

    /// Vision points are normalised per axis, so spacing is only meaningful once scaled back to pixels.
    private static func scaled(_ joint: VNRecognizedPoint?, _ size: CGSize) -> CGPoint? {
        guard let joint, joint.confidence >= minConfidence else { return nil }
        return CGPoint(x: joint.location.x * size.width, y: joint.location.y * size.height)
    }
}
