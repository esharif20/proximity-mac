import Foundation
import PresenceCore
import Testing

@Suite struct DistanceTests {
    @Test func uncalibratedUsesPinholeModel() {
        // 70 degree field of view across 1000 px: focal length 500 / tan(35 deg) = 714.07 px.
        // A 15 cm face 178.5 px wide is then 60 cm away.
        let d = Distance.estimate(faceWidthPx: 178.5, imageWidthPx: 1000, calibration: nil)
        #expect(abs(d - 60.0) < 0.1)
    }

    @Test func calibratedFaceAtCalibrationWidthIsAtCalibrationDistance() {
        let cal = Calibration(faceWidthPx: 200, imageWidthPx: 1280, distanceCm: 55)
        #expect(Distance.estimate(faceWidthPx: 200, imageWidthPx: 1280, calibration: cal) == 55)
        // Half the width at the same image size is twice as far.
        #expect(Distance.estimate(faceWidthPx: 100, imageWidthPx: 1280, calibration: cal) == 110)
        // Same face at half the image resolution is the same distance.
        #expect(Distance.estimate(faceWidthPx: 100, imageWidthPx: 640, calibration: cal) == 55)
    }

    @Test func shouldersUseThePinholeModelAt36Centimetres() {
        // Focal length 714.07 px across 1000 px: 36 cm shoulders 428.4 px apart are 60 cm away.
        let d = Distance.estimate(shoulderWidthPx: 428.4, imageWidthPx: 1000, calibration: nil)
        #expect(abs(d - 60.0) < 0.1)
    }

    @Test func handsUseThePinholeModelAt10Centimetres() {
        // A 10 cm wrist-to-middle-knuckle length 119 px long is 60 cm away.
        let d = Distance.estimate(handLengthPx: 119.0, imageWidthPx: 1000, calibration: nil)
        #expect(abs(d - 60.0) < 0.1)
    }

    @Test func shouldersAndHandsFollowTheFaceCalibration() {
        // A person whose face is wider than average reads nearer; their body is assumed to scale the same way.
        let cal = Calibration(faceWidthPx: 150, imageWidthPx: 640, distanceCm: 60)
        #expect(abs(Distance.estimate(shoulderWidthPx: 360, imageWidthPx: 640, calibration: cal) - 60) < 0.001)
        #expect(abs(Distance.estimate(handLengthPx: 100, imageWidthPx: 640, calibration: cal) - 60) < 0.001)
        #expect(abs(Distance.estimate(shoulderWidthPx: 180, imageWidthPx: 640, calibration: cal) - 120) < 0.001)
    }

    @Test func zeroSizedJointsAreInfinitelyFar() {
        #expect(Distance.estimate(shoulderWidthPx: 0, imageWidthPx: 640, calibration: nil) == .infinity)
        #expect(Distance.estimate(handLengthPx: -3, imageWidthPx: 640, calibration: nil) == .infinity)
    }

    @Test func zeroWidthFaceIsInfinitelyFar() {
        #expect(Distance.estimate(faceWidthPx: 0, imageWidthPx: 1000, calibration: nil) == .infinity)
    }

    @Test func smallerFaceIsAlwaysFarther() {
        var g = Gen(seed: 7)
        for _ in 0..<2000 {
            let image = Double.random(in: 320...4096, using: &g)
            let a = Double.random(in: 1...image, using: &g)
            let b = Double.random(in: 1...image, using: &g)
            guard a != b else { continue }
            let cal: Calibration? = Bool.random(using: &g)
                ? Calibration(faceWidthPx: .random(in: 20...800, using: &g),
                              imageWidthPx: .random(in: 320...4096, using: &g),
                              distanceCm: .random(in: 30...150, using: &g))
                : nil
            let (small, big) = (min(a, b), max(a, b))
            #expect(Distance.estimate(faceWidthPx: small, imageWidthPx: image, calibration: cal)
                > Distance.estimate(faceWidthPx: big, imageWidthPx: image, calibration: cal))
        }
    }

    @Test func resultDoesNotDependOnImageWidth() {
        var g = Gen(seed: 11)
        for _ in 0..<2000 {
            let image = Double.random(in: 320...4096, using: &g)
            let face = Double.random(in: 1...image, using: &g)
            let scale = Double.random(in: 0.25...4, using: &g)
            let cal: Calibration? = Bool.random(using: &g)
                ? Calibration(faceWidthPx: .random(in: 20...800, using: &g),
                              imageWidthPx: .random(in: 320...4096, using: &g),
                              distanceCm: .random(in: 30...150, using: &g))
                : nil
            let d1 = Distance.estimate(faceWidthPx: face, imageWidthPx: image, calibration: cal)
            let d2 = Distance.estimate(faceWidthPx: face * scale, imageWidthPx: image * scale, calibration: cal)
            #expect(abs(d1 - d2) <= 1e-9 * d1)
        }
    }

    @Test func calibrationTakesTheMedian() {
        let cal = Distance.calibration(fromFaceWidths: [200, 210, 190, 205, 200], imageWidthPx: 1280, distanceCm: 60)
        #expect(cal == Calibration(faceWidthPx: 200, imageWidthPx: 1280, distanceCm: 60))
        let even = Distance.calibration(fromFaceWidths: [200, 202, 204, 206, 208, 210], imageWidthPx: 1280, distanceCm: 60)
        #expect(even?.faceWidthPx == 205)
    }

    @Test func calibrationNeedsFiveSamples() {
        #expect(Distance.calibration(fromFaceWidths: [200, 200, 200, 200], imageWidthPx: 1280, distanceCm: 60) == nil)
        #expect(Distance.calibration(fromFaceWidths: [], imageWidthPx: 1280, distanceCm: 60) == nil)
    }

    @Test func calibrationRejectsWildSpread() {
        #expect(Distance.calibration(fromFaceWidths: [100, 200, 300, 400, 500], imageWidthPx: 1280, distanceCm: 60) == nil)
        #expect(Distance.calibration(fromFaceWidths: [200, 200, 200, 200, 0], imageWidthPx: 1280, distanceCm: 60) == nil)
        #expect(Distance.calibration(fromFaceWidths: [200, 200, 200, 200, .nan], imageWidthPx: 1280, distanceCm: 60) == nil)
        #expect(Distance.calibration(fromFaceWidths: [200, 200, 200, 200, 200], imageWidthPx: 0, distanceCm: 60) == nil)
    }

    @Test func personShareFollowsTheInverseSquareRoot() {
        #expect(abs(Distance.estimate(personShare: 0.30) - 60) < 0.001)
        #expect(abs(Distance.estimate(personShare: 0.075) - 120) < 0.001, "a quarter of the area is twice as far")
        #expect(Distance.estimate(personShare: 0.15) < 120, "a seated person at 15% is inside the default Desk radius")
        #expect(Distance.estimate(personShare: 0.02) > 200, "a few percent is across the room")
        #expect(Distance.estimate(personShare: 0) == .infinity)
        #expect(Distance.estimate(personShare: .nan) == .infinity)
    }
}
