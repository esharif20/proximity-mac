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

    /// The passes tried when no face is found, run lazily so a pass that answers saves the rest.
    struct FacelessPasses {
        var body: () -> BodyJoints?
        /// The widest upper-body box, in pixels.
        var box: () -> Double?
        var hands: () -> [HandJoints]
    }

    /// Body pose first, since it sees a torso with the head above the frame; then the upper-body box; hands
    /// last, so a person already seen far away is never turned into a close one by a stray hand. Body and
    /// hand pose run only when `fullChain` is set: on every Checking pass, since someone looking down at a
    /// phone barely moves, and on motion passes while Watching, so an empty still room then costs only the
    /// face and box passes.
    static func observationWithoutFace(
        fullChain: Bool, passes: FacelessPasses, imageWidthPx: Double, calibration: Calibration?, deskRadiusCm: Double,
        brightness: Double?
    ) -> Observation {
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
