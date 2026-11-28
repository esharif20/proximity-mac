import CoreGraphics
import Testing
@testable import PresenceSensors

@Suite struct VisionLabGeometryTests {
    @Test(arguments: [
        (CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)),
        (CGPoint(x: 0.2, y: 0.9), CGPoint(x: 0.8, y: 0.1)),
        (CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.5, y: 0.5)),
    ])
    func pointsFlipToTopLeftAndMirror(vision: CGPoint, lab: CGPoint) {
        let p = LabGeometry.mirrored(vision)
        #expect(abs(p.x - lab.x) < 1e-9 && abs(p.y - lab.y) < 1e-9)
    }

    @Test func aBoxOnTheCameraLeftLowDownShowsOnTheRightLowDown() {
        // Vision: left side of the camera image, near the bottom (small y).
        let box = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.3)
        let lab = LabGeometry.mirrored(box)
        #expect(abs(lab.minX - 0.7) < 1e-9)
        #expect(abs(lab.minY - 0.6) < 1e-9)
        #expect(lab.size == box.size)
    }

    @Test func mirroringTwiceIsIdentity() {
        let box = CGRect(x: 0.13, y: 0.41, width: 0.27, height: 0.19)
        let back = LabGeometry.mirrored(LabGeometry.mirrored(box))
        #expect(abs(back.minX - box.minX) < 1e-9 && abs(back.minY - box.minY) < 1e-9)
    }

    @Test func landmarksAreRelativeToTheFaceBox() {
        let box = CGRect(x: 0.4, y: 0.2, width: 0.2, height: 0.4)
        // The box's bottom-left corner in Vision space is its top-right corner once mirrored.
        let corner = LabGeometry.landmark(CGPoint(x: 0, y: 0), in: box)
        #expect(abs(corner.x - 0.6) < 1e-9 && abs(corner.y - 0.8) < 1e-9)
        let centre = LabGeometry.landmark(CGPoint(x: 0.5, y: 0.5), in: box)
        #expect(abs(centre.x - 0.5) < 1e-9 && abs(centre.y - 0.6) < 1e-9)
    }

    @Test func horizontalAngleIsZeroOnAxisAndHalfTheFieldAtTheEdges() {
        #expect(abs(LabGeometry.horizontalAngle(mirroredX: 0.5)) < 1e-9)
        let half = LabGeometry.horizontalFieldOfViewDegrees / 2
        #expect(abs(LabGeometry.horizontalAngle(mirroredX: 1) - half) < 1e-9)
        #expect(abs(LabGeometry.horizontalAngle(mirroredX: 0) + half) < 1e-9)
    }

    @Test func horizontalAngleIsSymmetricAndMonotonic() {
        let xs = stride(from: 0.0, through: 1.0, by: 0.05).map { $0 }
        let angles = xs.map(LabGeometry.horizontalAngle(mirroredX:))
        #expect(angles == angles.sorted())
        for x in xs {
            #expect(abs(LabGeometry.horizontalAngle(mirroredX: x) + LabGeometry.horizontalAngle(mirroredX: 1 - x)) < 1e-9)
        }
        // Pinhole, not linear: a quarter of the way out is less than a quarter of the field.
        #expect(LabGeometry.horizontalAngle(mirroredX: 0.75) > LabGeometry.horizontalFieldOfViewDegrees / 4)
    }

    @Test func handsHaveTwentyOneDistinctJoints() {
        #expect(LabGeometry.handJoints.count == 21)
        #expect(Set(LabGeometry.handJoints.map(\.rawValue)).count == 21)
        #expect(LabGeometry.missingJoint.x.isNaN)
    }
}

@Suite struct VisionLabFrameDroppingTests {
    @Test func aFrameArrivingWhileBusyIsDropped() {
        let gate = BusyGate()
        #expect(gate.tryEnter())
        #expect(!gate.tryEnter())
        #expect(!gate.tryEnter())
        gate.leave()
        #expect(gate.tryEnter())
    }

    @Test func concurrentArrivalsLetExactlyOneIn() async {
        let gate = BusyGate()
        let admitted = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<64 { group.addTask { gate.tryEnter() } }
            return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        #expect(admitted == 1)
    }

    @Test func frameRateSettlesOnTheDeliveredRate() {
        var rate = FrameRate()
        var fps = 0.0
        for i in 0..<200 { fps = rate.tick(at: Double(i) / 20) }
        #expect(abs(fps - 20) < 0.01)
        // One slow frame moves the readout only a little.
        fps = rate.tick(at: 10 + 0.5)
        #expect(fps > 17 && fps < 20)
    }

    @Test func aRepeatedTimestampDoesNotDivideByZero() {
        var rate = FrameRate()
        _ = rate.tick(at: 1)
        #expect(rate.tick(at: 1) == 0)
    }
}

@Suite struct VisionLabEnrolmentTests {
    @Test func turnedAwayOrBlurredFacesAreRejected() {
        var filter = EnrolmentFilter()
        do { let kept = filter.accept(yawDeg: 40, pitchDeg: 0, quality: 0.9); #expect(!kept) }
        do { let kept = filter.accept(yawDeg: -35, pitchDeg: 0, quality: 0.9); #expect(!kept) }
        do { let kept = filter.accept(yawDeg: 0, pitchDeg: 0, quality: 0.1); #expect(!kept) }
        do { let kept = filter.accept(yawDeg: -34, pitchDeg: 0, quality: 0.5); #expect(kept) }
    }

    @Test func nearDuplicatePosesAreSkipped() {
        var filter = EnrolmentFilter()
        do { let kept = filter.accept(yawDeg: 0, pitchDeg: 0, quality: 0.8); #expect(kept) }
        do { let kept = filter.accept(yawDeg: 1, pitchDeg: -1, quality: 0.8); #expect(!kept) }
        do { let kept = filter.accept(yawDeg: 2.9, pitchDeg: 2.9, quality: 0.8); #expect(!kept) }
        // Far enough in yaw alone, or in pitch alone, is a new pose.
        do { let kept = filter.accept(yawDeg: 3, pitchDeg: 0, quality: 0.8); #expect(kept) }
        do { let kept = filter.accept(yawDeg: 0, pitchDeg: 3, quality: 0.8); #expect(kept) }
        #expect(filter.poses.count == 3)
    }

    @Test func aCandidateIsNotUsedUpUntilItsEmbeddingIsRecorded() {
        var filter = EnrolmentFilter()
        #expect(filter.isCandidate(yawDeg: 0, pitchDeg: 0, quality: 0.8))
        // The embedding failed, so nothing is recorded and the same pose is still wanted.
        #expect(filter.isCandidate(yawDeg: 0.5, pitchDeg: 0, quality: 0.8))
        filter.record(yawDeg: 0.5, pitchDeg: 0)
        #expect(!filter.isCandidate(yawDeg: 0, pitchDeg: 0, quality: 0.8))
    }

    @Test func aStillFaceGivesOneSampleAndASweepGivesMany() {
        var still = EnrolmentFilter()
        let stillKept = (0..<300).filter { i in
            still.accept(yawDeg: sin(Double(i)) * 0.5, pitchDeg: cos(Double(i)) * 0.5, quality: 0.8)
        }
        #expect(stillKept.count == 1)

        var sweep = EnrolmentFilter()
        // Turning slowly from left to right and back, nodding a little.
        let sweepKept = (0..<300).filter { i in
            let t = Double(i) / 300 * 2 * .pi
            return sweep.accept(yawDeg: sin(t) * 30, pitchDeg: sin(3 * t) * 10, quality: 0.8)
        }
        #expect(sweepKept.count >= 20)
        for (i, a) in sweep.poses.enumerated() {
            for b in sweep.poses[(i + 1)...] {
                #expect(abs(a.yaw - b.yaw) >= 3 || abs(a.pitch - b.pitch) >= 3)
            }
        }
    }
}

@Suite struct VisionLabCaptureTests {
    @Test func capturesFourByThreeLikeCameraSource() throws {
        let formats = [(width: 1920, height: 1080), (width: 1280, height: 720), (width: 640, height: 480),
                       (width: 960, height: 720), (width: 1760, height: 1328), (width: 320, height: 240)]
        let index = try #require(VisionLab.captureFormatIndex(formats))
        #expect(formats[index] == (960, 720))
    }

    @Test func noFourByThreeFormatFallsBackToThePreset() {
        #expect(VisionLab.captureFormatIndex([(1280, 720), (1920, 1080)]) == nil)
    }

    @Test func aCalibrationMadeHereGivesTheSameDistanceInCameraSource() throws {
        // The same face at 60 cm fills the same share of any 4:3 frame.
        let labWidth = 960.0
        let cal = try #require(Distance.calibration(
            fromFaceWidths: Array(repeating: 0.2 * labWidth, count: 6), imageWidthPx: labWidth, distanceCm: 60))
        let there = Distance.estimate(faceWidthPx: 0.2 * CameraSource.captureWidthPx, imageWidthPx: CameraSource.captureWidthPx, calibration: cal)
        #expect(abs(there - 60) < 1e-9)
    }

    @Test func frameRateIsClampedToFifteenToThirty() throws {
        func fps(_ ranges: [(min: Double, max: Double)]) throws -> [Double] {
            let r = try #require(VisionLab.frameRate(ranges: ranges))
            return [r.min, r.max]
        }
        #expect(try fps([(1, 30)]) == [15, 30])
        #expect(try fps([(2, 60)]) == [15, 30])
        #expect(try fps([(15, 15)]) == [15, 15])
        #expect(try fps([(5, 10), (20, 60)]) == [20, 30])
    }

    @Test func aFormatOutsideTheRangeGetsNoFrameRateChange() {
        #expect(VisionLab.frameRate(ranges: [(min: 1, max: 10)]) == nil)
    }
}

@Suite struct VisionLabLifecycleTests {
    @Test func stopReturnsWithTheCameraReleased() {
        let lab = VisionLab()
        lab.start { _ in }
        lab.stop()
        #expect(!lab.hasSession, "the presence camera starts straight after stop()")
    }

    @Test func stopWithoutStartIsSafe() {
        let lab = VisionLab()
        lab.stop()
    }

    @Test func calibrateAndEnrolGiveUpWhenNotRunning() async {
        let lab = VisionLab()
        #expect(await lab.calibrate(seconds: 0.1) == nil)
        #expect(await lab.enrolOwner(samples: 2) { _ in } == nil)
    }

    @Test func calibrationIsKeptForDistance() {
        let lab = VisionLab()
        let calibration = Calibration(faceWidthPx: 200, imageWidthPx: 1280)
        lab.calibration = calibration
        #expect(lab.calibration == calibration)
    }
}
