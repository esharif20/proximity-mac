import SwiftUI
import struct PresenceSensors.LabFrame
import struct PresenceSensors.LabFace
import struct PresenceSensors.LabHand

/// The camera image with the vision drawn on top, in one Canvas so image and overlay share a single
/// transform and redraw together once per frame. Nothing here animates: overlays track the frame 1:1.
struct VisionStage: View {
    let frame: LabFrame?
    var gazeTargets: [GazeTarget: Bool]?

    var body: some View {
        Canvas { context, size in
            guard let frame else { return }
            let imageSize = CGSize(width: frame.image.width, height: frame.image.height)
            // Aspect-fill, the same mapping the overlays use, so points land on the face.
            let scale = max(size.width / imageSize.width, size.height / imageSize.height)
            let drawn = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            let rect = CGRect(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2,
                              width: drawn.width, height: drawn.height)
            context.draw(Image(decorative: frame.image, scale: 1), in: rect)
            let map = PointMap(rect: rect)

            if let body = frame.body {
                context.stroke(Path(roundedRect: map.rect(body), cornerRadius: 6), with: .color(.white.opacity(0.25)),
                               style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            for hand in frame.hands { drawHand(hand, map: map, in: &context) }
            if let face = frame.face {
                drawFace(face, map: map, in: &context)
                if let gazeTargets { drawGaze(face, targets: gazeTargets, map: map, size: size, in: &context) }
            }
        }
        .background(.black)
        .overlay {
            // A soft vignette so white strokes read on any background.
            RadialGradient(colors: [.clear, .black.opacity(0.45)], center: .center, startRadius: 180, endRadius: 520)
                .allowsHitTesting(false)
        }
    }

    private func drawFace(_ face: LabFace, map: PointMap, in context: inout GraphicsContext) {
        for point in face.landmarks {
            let p = map.point(point)
            context.fill(Path(ellipseIn: CGRect(x: p.x - 1.5, y: p.y - 1.5, width: 3, height: 3)), with: .color(.white.opacity(0.85)))
        }
        let box = map.rect(face.box)
        context.stroke(cornerBrackets(box, length: min(box.width, box.height) * 0.22),
                       with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        let label = Text("\(Int(face.distanceCm.rounded())) cm")
            .font(.system(.callout, design: .rounded).weight(.semibold).monospacedDigit())
            .foregroundStyle(.white)
        context.draw(label, at: CGPoint(x: box.minX, y: box.minY - 8), anchor: .bottomLeading)
        drawAxes(face, at: CGPoint(x: box.midX, y: box.midY + box.height * 0.05), in: &context)
    }

    /// A three-axis gizmo: X right, Y up, Z out of the face, rotated by the head pose.
    private func drawAxes(_ face: LabFace, at origin: CGPoint, in context: inout GraphicsContext) {
        let yaw = face.yawDeg * .pi / 180, pitch = face.pitchDeg * .pi / 180, roll = face.rollDeg * .pi / 180
        func project(_ v: (Double, Double, Double)) -> CGPoint {
            // Roll (z), then pitch (x), then yaw (y); orthographic projection onto the screen.
            var (x, y, z) = v
            (x, y) = (x * cos(roll) - y * sin(roll), x * sin(roll) + y * cos(roll))
            (y, z) = (y * cos(pitch) - z * sin(pitch), y * sin(pitch) + z * cos(pitch))
            (x, z) = (x * cos(yaw) + z * sin(yaw), -x * sin(yaw) + z * cos(yaw))
            return CGPoint(x: origin.x + x * 40, y: origin.y - y * 40)
        }
        for (axis, opacity) in [((1.0, 0.0, 0.0), 0.95), ((0.0, 1.0, 0.0), 0.7), ((0.0, 0.0, 1.0), 0.45)] {
            var path = Path()
            path.move(to: origin)
            path.addLine(to: project(axis))
            context.stroke(path, with: .color(.white.opacity(opacity)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
    }

    private func drawHand(_ hand: LabHand, map: PointMap, in context: inout GraphicsContext) {
        guard let wrist = hand.joints.first else { return }
        var bones = Path()
        // Vision orders joints wrist first, then four per finger from knuckle to tip.
        for finger in 0..<5 {
            var previous = map.point(wrist)
            for joint in 0..<4 {
                let index = 1 + finger * 4 + joint
                guard index < hand.joints.count else { break }
                let p = map.point(hand.joints[index])
                // A joint Vision could not see is NaN; skip the bone rather than draw to nowhere.
                if p.x.isFinite, previous.x.isFinite {
                    bones.move(to: previous)
                    bones.addLine(to: p)
                }
                previous = p
            }
        }
        context.stroke(bones, with: .color(.white.opacity(0.6)), lineWidth: 1)
        for joint in hand.joints where joint.x.isFinite {
            let p = map.point(joint)
            context.fill(Path(ellipseIn: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)), with: .color(.white))
        }
    }

    private func drawGaze(_ face: LabFace, targets: [GazeTarget: Bool], map: PointMap, size: CGSize, in context: inout GraphicsContext) {
        let box = map.rect(face.box)
        let start = CGPoint(x: box.midX, y: box.minY + box.height * 0.4)
        let reach = size.height * 0.35
        let end = CGPoint(x: start.x + sin(face.yawDeg * .pi / 180) * reach * 1.6,
                          y: start.y - reach + sin(face.pitchDeg * .pi / 180) * reach * 0.5)
        var ray = Path()
        ray.move(to: start)
        ray.addLine(to: end)
        context.stroke(ray, with: .linearGradient(Gradient(colors: [.accentColor, .accentColor.opacity(0)]),
                                                  startPoint: start, endPoint: end),
                       style: StrokeStyle(lineWidth: 3, lineCap: .round))
        for (index, target) in GazeTarget.allCases.enumerated() {
            let lit = targets[target] ?? false
            let centre = CGPoint(x: size.width * (0.2 + 0.3 * Double(index)), y: 44)
            let rect = CGRect(x: centre.x - 34, y: centre.y - 14, width: 68, height: 28)
            let shape = Path(roundedRect: rect, cornerRadius: 6)
            context.fill(shape, with: .color(lit ? .accentColor.opacity(0.85) : .white.opacity(0.08)))
            context.stroke(shape, with: .color(.white.opacity(lit ? 0.9 : 0.35)), lineWidth: 1)
        }
    }

    private func cornerBrackets(_ r: CGRect, length l: CGFloat) -> Path {
        var p = Path()
        for (corner, dx, dy) in [(CGPoint(x: r.minX, y: r.minY), 1.0, 1.0), (CGPoint(x: r.maxX, y: r.minY), -1.0, 1.0),
                                 (CGPoint(x: r.minX, y: r.maxY), 1.0, -1.0), (CGPoint(x: r.maxX, y: r.maxY), -1.0, -1.0)] {
            p.move(to: CGPoint(x: corner.x + dx * l, y: corner.y))
            p.addLine(to: corner)
            p.addLine(to: CGPoint(x: corner.x, y: corner.y + dy * l))
        }
        return p
    }
}

/// Maps the contract's normalised points (0 to 1, top-left origin, already mirrored) into the drawn image.
private struct PointMap {
    let rect: CGRect

    func point(_ p: CGPoint) -> CGPoint {
        CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height)
    }

    func rect(_ r: CGRect) -> CGRect {
        CGRect(origin: point(r.origin), size: CGSize(width: r.width * rect.width, height: r.height * rect.height))
    }
}

/// The quiet corner readout: frame rate, Vision time per frame and the app's CPU.
struct SetupHUD: View {
    let frame: LabFrame?
    let cpuPercent: Double
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let fps = frame.map { String(format: "%.0f fps", $0.fps) } ?? "-- fps"
        let ms = frame.map { String(format: "%.1f ms", $0.visionMs) } ?? "-- ms"
        Text("\(fps)  ·  \(ms)  ·  CPU \(Int(cpuPercent.rounded()))%")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                if reduceTransparency { Capsule().fill(Color(white: 0.12)) }
            }
            .glassEffect(reduceTransparency ? .identity : .regular, in: .capsule)
    }
}
