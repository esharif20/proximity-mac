import Foundation
import Testing
@testable import PresenceSensors

@Suite struct CameraSourceTests {
    typealias Face = CameraSource.FaceMeasure

    static func observe(face: Face? = nil, body: Double? = nil, width: Double = 640, calibration: Calibration? = nil) -> Observation {
        CameraSource.observation(face: face, bodyWidthPx: body, imageWidthPx: width, calibration: calibration)
    }

    @Test func nobodySeenHasNoDistance() {
        let o = Self.observe()
        #expect(!o.person)
        #expect(o.distanceCm == nil)
        #expect(o.facingScreen == nil)
        #expect(o.source == .camera)
    }

    @Test func faceDistanceComesFromCore() {
        let o = Self.observe(face: Face(widthPx: 120, yawDegrees: 0, pitchDegrees: 0))
        #expect(o.person)
        #expect(o.distanceCm == Distance.estimate(faceWidthPx: 120, imageWidthPx: 640, calibration: nil))
    }

    @Test func calibrationIsPassedThrough() {
        let cal = Calibration(faceWidthPx: 160, imageWidthPx: 640, distanceCm: 60)
        let o = Self.observe(face: Face(widthPx: 80), calibration: cal)
        #expect(abs((o.distanceCm ?? 0) - 120) < 0.001)
    }

    @Test func upperBodyAloneGetsADistance() throws {
        // A person lying side-on: no face, a body box. Shoulders 40 cm, face 15 cm.
        let o = Self.observe(body: 200)
        #expect(o.person)
        let d = try #require(o.distanceCm)
        #expect(abs(d - Distance.estimate(faceWidthPx: 75, imageWidthPx: 640, calibration: nil)) < 0.001)
        #expect(o.facingScreen == nil)
    }

    @Test func aFarBodyIsNotClose() throws {
        let o = Self.observe(body: 40)
        #expect(try #require(o.distanceCm) > Settings().deskRadiusCm)
    }

    @Test func faceWinsOverBody() {
        let o = Self.observe(face: Face(widthPx: 120), body: 10)
        #expect(o.distanceCm == Distance.estimate(faceWidthPx: 120, imageWidthPx: 640, calibration: nil))
    }

    @Test(arguments: [
        (0.0, 0.0, true), (30.0, 25.0, true), (-30.0, -25.0, true),
        (31.0, 0.0, false), (0.0, 26.0, false), (-45.0, 10.0, false),
    ])
    func facingLimits(yaw: Double, pitch: Double, facing: Bool) {
        #expect(Self.observe(face: Face(widthPx: 100, yawDegrees: yaw, pitchDegrees: pitch)).facingScreen == facing)
    }

    @Test func facingUnknownWithoutPose() {
        #expect(Self.observe(face: Face(widthPx: 100, yawDegrees: nil, pitchDegrees: 3)).facingScreen == nil)
    }

    @Test func distanceIsAlwaysFiniteAndEncodable() throws {
        let cases: [(Face?, Double?)] = [
            (Face(widthPx: 0), nil), (nil, 0), (Face(widthPx: -5), nil), (Face(widthPx: .nan), nil),
            (Face(widthPx: 1e-9), nil), (nil, .infinity), (Face(widthPx: 1e9), nil),
        ]
        for (face, body) in cases {
            for width in [0.0, 640, 1e-6] {
                let o = Self.observe(face: face, body: body, width: width)
                let d = try #require(o.distanceCm)
                #expect(d.isFinite && d >= 0)
                _ = try JSONEncoder().encode(TraceLine(t: 1, event: .observation(o)))
            }
        }
    }

    @Test func randomSightingsAreFiniteAndEncodable() throws {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<2000 {
            let face = Bool.random(using: &rng) ? Face(widthPx: .random(in: -10...2000, using: &rng)) : nil
            let body = Bool.random(using: &rng) ? Double.random(in: -10...2000, using: &rng) : nil
            let cal = Bool.random(using: &rng)
                ? Calibration(faceWidthPx: .random(in: 0...400, using: &rng), imageWidthPx: .random(in: 0...1920, using: &rng))
                : nil
            let o = Self.observe(face: face, body: body, width: .random(in: 0...1920, using: &rng), calibration: cal)
            #expect(o.person == (face != nil || body != nil))
            #expect((o.distanceCm == nil) == !o.person)
            if let d = o.distanceCm { #expect(d.isFinite) }
            _ = try JSONEncoder().encode(o)
        }
    }

    @Test(arguments: [(SamplingMode.off, nil as Double?), (.checking, 1), (.watching, 2)])
    func modeIntervals(mode: SamplingMode, interval: Double?) {
        #expect(FrameThrottle.interval(for: mode) == interval)
    }

    @Test func throttleKeepsAboutOneFramePerInterval() {
        var throttle = FrameThrottle(interval: 1)
        // 30 fps for 10 s.
        let taken = (0..<300).filter { throttle.shouldSample(at: Double($0) / 30) }.count
        // The early tolerance lets in up to about 10% more, still about one a second.
        #expect((10...12).contains(taken))
        var off = FrameThrottle(interval: nil)
        #expect(!(0..<300).contains { off.shouldSample(at: Double($0)) })
    }

    @Test func calibrationPropertyRoundTrips() {
        let source = CameraSource()
        #expect(source.calibration == nil)
        let cal = Calibration(faceWidthPx: 150, imageWidthPx: 640)
        source.calibration = cal
        #expect(source.calibration == cal)
        #expect(source.kind == .camera)
        source.setMode(.off)
    }

    @Test(arguments: [(SamplingMode.checking, 1.0), (.watching, 2.0)])
    func jitteredFramesAtTheSampleRateAreAllKept(mode: SamplingMode, period: Double) {
        // A 1 fps external camera in checking: gaps jitter just under and over the interval.
        var throttle = FrameThrottle(interval: FrameThrottle.interval(for: mode))
        let jitter = [-0.004, 0.003, -0.002, 0.001, -0.003]
        var t = 0.0
        var taken = 0
        for i in 0..<100 {
            t += period + jitter[i % jitter.count]
            if throttle.shouldSample(at: t) { taken += 1 }
        }
        #expect(taken == 100)
    }

    @Test func throttleStillDropsFramesWellInsideTheInterval() {
        var throttle = FrameThrottle(interval: 2)
        let taken = [0, 1, 1.7, 2].map { throttle.shouldSample(at: $0) }
        #expect(taken == [true, false, false, true])
    }

    @Test func sensorRateLeavesSeveralFramesPerSampleOnASlowCamera() throws {
        // This Mac's external camera reports 1-30 fps; the built-in one 15-30.
        let external = [(min: 1.0, max: 30.0)]
        let sampling = try #require(CameraSource.sensorFrameRate(ranges: external, calibrating: false))
        #expect(sampling >= 2, "at least two frames per checking sample")
        let calibrating = try #require(CameraSource.sensorFrameRate(ranges: external, calibrating: true))
        #expect(calibrating * (CameraSource.calibrationSeconds - 0.5) >= 5 * 2, "comfortably more than the 5 widths calibration needs")
        #expect(CameraSource.sensorFrameRate(ranges: [(min: 15, max: 30)], calibrating: false) == 15)
        #expect(CameraSource.sensorFrameRate(ranges: [(min: 1, max: 3)], calibrating: true) == 3)
        #expect(CameraSource.sensorFrameRate(ranges: [], calibrating: false) == nil)
    }
}
