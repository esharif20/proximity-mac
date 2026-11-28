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

    @Test func brightnessIsCarried() {
        let o = CameraSource.observation(body: Self.headCutOff, imageWidthPx: Self.width, calibration: nil, brightness: 0.2)
        #expect(o?.brightness == 0.2)
    }
}
