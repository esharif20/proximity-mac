import CoreGraphics
import Foundation
import PresenceCore
import PresenceSensors
import Synchronization

// Stand-ins with the exact signatures of the plan's contract (VisionLab, LabFrame,
// VoiceSource.onLevel) until the vision lane lands on main.
// Delete this file when they do; nothing else changes. The fake source draws no real camera image
// and keeps nothing.

public struct LabFrame: Sendable {
    public var image: CGImage
    public var face: LabFace?
    public var hands: [LabHand]
    public var body: CGRect?
    public var visionMs: Double
    public var fps: Double
}

public struct LabFace: Sendable {
    public var box: CGRect
    public var landmarks: [CGPoint]
    public var yawDeg, pitchDeg, rollDeg, distanceCm, horizontalAngleDeg: Double
}

public struct LabHand: Sendable {
    public var joints: [CGPoint]
    public var isLeft: Bool
}

extension VoiceSource {
    public func onLevel(_ handler: @escaping @Sendable (Float) -> Void) {}
}

public final class VisionLab: Sendable {
    private struct State {
        var timer: DispatchSourceTimer?
        var start = 0.0
    }

    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "VisionLab.fake")

    public init() {}

    public func start(_ onFrame: @escaping @Sendable (LabFrame) -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let start = ProcessInfo.processInfo.systemUptime
        timer.schedule(deadline: .now(), repeating: 1.0 / 15)
        timer.setEventHandler { onFrame(Self.frame(at: ProcessInfo.processInfo.systemUptime - start)) }
        state.withLock { s in
            s.timer?.cancel()
            s.timer = timer
            s.start = start
        }
        timer.resume()
    }

    public func stop() {
        state.withLock { s in
            s.timer?.cancel()
            s.timer = nil
        }
    }

    public func calibrate(seconds: Double = 3) async -> Calibration? {
        try? await Task.sleep(for: .seconds(seconds))
        return Calibration(faceWidthPx: 150, imageWidthPx: 640, distanceCm: 60)
    }

    public func enrolOwner(samples: Int = 20, progress: @escaping @Sendable (Int) -> Void) async -> FaceSignature? {
        for sample in 1...samples {
            try? await Task.sleep(for: .milliseconds(120))
            progress(sample)
        }
        return FaceSignature(vectors: [[Float](repeating: 0, count: 128)], threshold: 0.5)
    }

    /// A slow loop through every Setup step: close, leaning back, looking around, far away.
    private static func frame(at t: Double) -> LabFrame {
        let distance = 110 + 75 * sin(t / 6)
        let scale = 60 / distance
        let x = 0.5 + 0.12 * sin(t / 4)
        let size = 0.34 * scale
        let box = CGRect(x: x - size / 2, y: 0.42 - size * 0.6, width: size, height: size * 1.2)
        var landmarks: [CGPoint] = []
        for i in 0..<36 {
            let a = Double(i) / 36 * 2 * .pi
            landmarks.append(CGPoint(x: box.midX + cos(a) * box.width * 0.42, y: box.midY + sin(a) * box.height * 0.42))
        }
        for eye in [-1.0, 1.0] {
            landmarks.append(CGPoint(x: box.midX + eye * box.width * 0.18, y: box.midY - box.height * 0.1))
        }
        let face = LabFace(box: box, landmarks: landmarks, yawDeg: 35 * sin(t / 2.5), pitchDeg: 8 * sin(t / 3),
                           rollDeg: 4 * sin(t / 5), distanceCm: distance, horizontalAngleDeg: 25 * sin(t / 4))
        var hands: [LabHand] = []
        if sin(t / 3) > 0.3 {
            let wrist = CGPoint(x: x + 0.22, y: 0.82)
            let joints = (0..<21).map { i in
                CGPoint(x: wrist.x + Double(i % 5) * 0.012 - 0.024, y: wrist.y - Double(i / 5 + 1) * 0.025)
            }
            hands.append(LabHand(joints: joints, isLeft: false))
        }
        let body = CGRect(x: box.midX - size * 1.3, y: box.maxY, width: size * 2.6, height: 1 - box.maxY)
        return LabFrame(image: backdrop, face: t.truncatingRemainder(dividingBy: 40) < 37 ? face : nil,
                        hands: hands, body: body, visionMs: 7.5 + 1.5 * sin(t), fps: 15)
    }

    private static let backdrop: CGImage = {
        let width = 640, height = 480
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let colours = [CGColor(red: 0.16, green: 0.17, blue: 0.2, alpha: 1), CGColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1)]
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colours as CFArray, locations: [0, 1])!
        context.drawRadialGradient(gradient, startCenter: CGPoint(x: 320, y: 280), startRadius: 0,
                                   endCenter: CGPoint(x: 320, y: 280), endRadius: 420, options: .drawsAfterEndLocation)
        return context.makeImage()!
    }()
}
