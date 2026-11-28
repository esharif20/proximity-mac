import CoreGraphics
import Foundation
import Testing
@testable import PresenceSensors

/// Named `CameraSource...` so `--filter CameraSource` runs it with the rest of the camera tests.
@Suite struct CameraSourceBodyAndHandsTests {
    static let width = 640.0

    /// A person standing at the desk, seen from a camera angled for someone seated: the head is above the
    /// frame, so there is no nose, only the neck and both shoulders near the top edge (pixels, y down).
    static let headCutOff = BodyJoints(
        nose: nil, neck: CGPoint(x: 320, y: 20), leftShoulder: CGPoint(x: 200, y: 30), rightShoulder: CGPoint(x: 440, y: 30))

    @Test func aStandingPersonWithTheHeadCutOffIsSeen() throws {
        let o = try #require(CameraSource.observation(body: Self.headCutOff, imageWidthPx: Self.width, calibration: nil))
        #expect(o.person)
        #expect(o.owner == nil)
        #expect(o.facingScreen == nil)
        let d = try #require(o.distanceCm)
        #expect(abs(d - Distance.estimate(shoulderWidthPx: 240, imageWidthPx: Self.width, calibration: nil)) < 0.001)
        #expect(d < Settings().deskRadiusCm, "240 px shoulders on a 640 px frame is at the desk")
    }

    @Test func noseAndShouldersAlsoCount() throws {
        var joints = Self.headCutOff
        joints.neck = nil
        joints.nose = CGPoint(x: 320, y: 5)
        #expect(CameraSource.observation(body: joints, imageWidthPx: Self.width, calibration: nil)?.person == true)
    }

    @Test(arguments: [
        BodyJoints(nose: nil, neck: CGPoint(x: 320, y: 20), leftShoulder: CGPoint(x: 200, y: 30), rightShoulder: nil),
        BodyJoints(nose: nil, neck: nil, leftShoulder: CGPoint(x: 200, y: 30), rightShoulder: CGPoint(x: 440, y: 30)),
        BodyJoints(nose: CGPoint(x: 320, y: 5), neck: CGPoint(x: 320, y: 20), leftShoulder: nil, rightShoulder: nil),
    ])
    func tooFewJointsAreNotAPerson(joints: BodyJoints) {
        #expect(CameraSource.observation(body: joints, imageWidthPx: Self.width, calibration: nil) == nil)
    }

    @Test func shoulderSpacingIsMeasuredAcrossBothAxes() {
        // A person leaning: shoulders 300 px across and 400 px down are 500 px apart.
        let joints = BodyJoints(
            nose: nil, neck: CGPoint(x: 100, y: 100), leftShoulder: CGPoint(x: 0, y: 0), rightShoulder: CGPoint(x: 300, y: 400))
        #expect(joints.shoulderWidthPx == 500)
    }

    @Test func aHandAtTheDeskIsAPersonClose() throws {
        // A 10 cm hand 60 cm away on a 640 px frame is about 76 px from wrist to middle knuckle.
        let hand = HandJoints(wrist: CGPoint(x: 300, y: 300), middleKnuckle: CGPoint(x: 300, y: 224))
        let o = try #require(CameraSource.observation(hands: [hand], imageWidthPx: Self.width, calibration: nil))
        #expect(o.person)
        #expect(o.owner == nil, "a hand says nothing about who it is, so Only wake for me never wakes on it")
        #expect(abs(try #require(o.distanceCm) - 60) < 1)
    }

    @Test func theNearestHandWins() throws {
        let far = HandJoints(wrist: CGPoint(x: 0, y: 0), middleKnuckle: CGPoint(x: 40, y: 0))
        let near = HandJoints(wrist: CGPoint(x: 0, y: 0), middleKnuckle: CGPoint(x: 90, y: 0))
        let o = try #require(CameraSource.observation(hands: [far, near], imageWidthPx: Self.width, calibration: nil))
        #expect(o.distanceCm == Distance.estimate(handLengthPx: 90, imageWidthPx: Self.width, calibration: nil))
    }

    @Test func aFarOrMissingHandIsNotCounted() {
        // 20 px is about 2.3 m away: too small to trust as a hand.
        let tiny = HandJoints(wrist: CGPoint(x: 0, y: 0), middleKnuckle: CGPoint(x: 20, y: 0))
        #expect(CameraSource.observation(hands: [tiny], imageWidthPx: Self.width, calibration: nil) == nil)
        #expect(CameraSource.observation(hands: [], imageWidthPx: Self.width, calibration: nil) == nil)
    }

    @Test func jointDistancesAreFiniteAndClamped() throws {
        let squashed = BodyJoints(
            nose: nil, neck: CGPoint(x: 1, y: 1), leftShoulder: CGPoint(x: 1, y: 1), rightShoulder: CGPoint(x: 1, y: 1))
        let o = try #require(CameraSource.observation(body: squashed, imageWidthPx: Self.width, calibration: nil))
        #expect(o.distanceCm == CameraSource.farCm)
        let huge = BodyJoints(
            nose: nil, neck: CGPoint(x: 0, y: 0), leftShoulder: CGPoint(x: -1e9, y: 0), rightShoulder: CGPoint(x: 1e9, y: 0))
        let near = try #require(CameraSource.observation(body: huge, imageWidthPx: Self.width, calibration: nil))
        #expect(try #require(near.distanceCm) >= 0)
    }

    /// Records which passes ran, in order, so the fallback order and its laziness can be checked.
    final class Calls { var log: [String] = [] }

    static func faceless(
        moved: Bool = true, body: BodyJoints? = nil, box: Double? = nil, hands: [HandJoints] = [], deskRadiusCm: Double = 120,
        calls: Calls = Calls()
    ) -> Observation {
        CameraSource.observationWithoutFace(
            moved: moved,
            passes: .init(
                body: { calls.log.append("body"); return body },
                box: { calls.log.append("box"); return box },
                hands: { calls.log.append("hands"); return hands }),
            imageWidthPx: width, calibration: nil, deskRadiusCm: deskRadiusCm, brightness: nil)
    }

    static let closeHand = HandJoints(wrist: CGPoint(x: 300, y: 300), middleKnuckle: CGPoint(x: 300, y: 224))

    @Test func aFarBodyBoxBeatsAStrayHand() throws {
        // Someone in bed 3 m away under a blanket: no pose, a body box, and a misplaced hand detection.
        let calls = Calls()
        let o = Self.faceless(box: 55, hands: [Self.closeHand], calls: calls)
        #expect(o.person)
        #expect(try #require(o.distanceCm) > Settings().deskRadiusCm, "the far box answers, not the hand")
        #expect(calls.log == ["body", "box"], "hands never run once the box has answered")
    }

    @Test func bodyPoseAnswersFirst() {
        let calls = Calls()
        let o = Self.faceless(body: Self.headCutOff, box: 55, hands: [Self.closeHand], calls: calls)
        #expect(o.distanceCm == CameraSource.observation(body: Self.headCutOff, imageWidthPx: Self.width, calibration: nil)?.distanceCm)
        #expect(calls.log == ["body"])
    }

    @Test func aHandAnswersOnlyWhenNothingElseDoes() throws {
        let calls = Calls()
        let o = Self.faceless(hands: [Self.closeHand], calls: calls)
        #expect(o.person)
        #expect(abs(try #require(o.distanceCm) - 60) < 1)
        #expect(calls.log == ["body", "box", "hands"])
    }

    @Test func aStillFrameSkipsTheMotionPasses() {
        let calls = Calls()
        let o = Self.faceless(moved: false, body: Self.headCutOff, hands: [Self.closeHand], calls: calls)
        #expect(!o.person)
        #expect(calls.log == ["box"])
    }

    @Test func aHandCountsOnlyInsideTheDeskRadius() {
        // About 60 cm away.
        #expect(Self.faceless(hands: [Self.closeHand], deskRadiusCm: 50).person == false)
        #expect(Self.faceless(hands: [Self.closeHand], deskRadiusCm: 80).person)
        // A 40 px hand is about 114 cm away: inside a 300 cm Desk radius, still under the 150 cm floor.
        let far = HandJoints(wrist: .zero, middleKnuckle: CGPoint(x: 40, y: 0))
        #expect(Self.faceless(hands: [far], deskRadiusCm: 300).person)
        // A 25 px hand is about 183 cm: inside 300 cm but past what hand pose can be trusted at.
        let tooFar = HandJoints(wrist: .zero, middleKnuckle: CGPoint(x: 25, y: 0))
        #expect(Self.faceless(hands: [tooFar], deskRadiusCm: 300).person == false)
    }

    @Test func poseModelsAreDroppedWhenIdleOrWhenTheCameraStops() {
        var lifetime = PoseLifetime()
        let unused = lifetime.shouldDrop(at: 100, cameraStopped: true)
        #expect(!unused, "nothing to drop before first use")
        lifetime.used(at: 0)
        let early = lifetime.shouldDrop(at: 29, cameraStopped: false)
        let idle = lifetime.shouldDrop(at: 31, cameraStopped: false)
        let again = lifetime.shouldDrop(at: 32, cameraStopped: true)
        #expect([early, idle, again] == [false, true, false], "dropped once after 30 s idle, then nothing left")
        lifetime.used(at: 40)
        let stopped = lifetime.shouldDrop(at: 41, cameraStopped: true)
        #expect(stopped, "the camera stopping drops them at once")
    }

    @Test func brightnessIsCarried() {
        let o = CameraSource.observation(body: Self.headCutOff, imageWidthPx: Self.width, calibration: nil, brightness: 0.2)
        #expect(o?.brightness == 0.2)
    }
}
