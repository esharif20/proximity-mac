import SwiftUI

/// A top-down room: the screen at the bottom centre, the desk radius as a glowing arc, and a dot for
/// the person placed by distance and horizontal angle.
struct RoomMap: View {
    /// Distance and angle of the face, when one is seen.
    var person: (distanceCm: Double, angleDeg: Double)?
    var radiusCm: Double
    var counted: Bool?
    /// The map's reach from the screen, in cm.
    static let rangeCm = 350.0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let origin = CGPoint(x: size.width / 2, y: size.height - 28)
            let scale = (size.height - 48) / Self.rangeCm
            ZStack {
                Canvas { context, _ in
                    // Faint range rings every metre, for scale.
                    for metre in 1...3 {
                        let r = Double(metre) * 100 * scale
                        context.stroke(arc(origin, r), with: .color(.white.opacity(0.08)), lineWidth: 1)
                    }
                    let r = radiusCm * scale
                    // Glow first, then the crisp arc on top.
                    var glow = context
                    glow.addFilter(.blur(radius: 6))
                    glow.stroke(arc(origin, r), with: .color(.accentColor.opacity(0.6)), lineWidth: 6)
                    context.fill(sector(origin, r), with: .color(.accentColor.opacity(0.08)))
                    context.stroke(arc(origin, r), with: .color(.accentColor), lineWidth: 2)
                    // The screen and desk.
                    let desk = CGRect(x: origin.x - 36, y: origin.y - 2, width: 72, height: 14)
                    context.fill(Path(roundedRect: desk, cornerRadius: 3), with: .color(.white.opacity(0.12)))
                    context.fill(Path(roundedRect: CGRect(x: origin.x - 22, y: origin.y - 4, width: 44, height: 4), cornerRadius: 2),
                                 with: .color(.white.opacity(0.8)))
                }
                if let person {
                    let angle = person.angleDeg * .pi / 180
                    let d = min(person.distanceCm, Self.rangeCm) * scale
                    Circle()
                        .fill(counted == true ? Color.accentColor : Color.white.opacity(0.7))
                        .frame(width: 14, height: 14)
                        .shadow(color: counted == true ? .accentColor : .clear, radius: 6)
                        .position(x: origin.x + sin(angle) * d, y: origin.y - cos(angle) * d)
                        // Smooths sensor noise without visible lag.
                        .animation(reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 1), value: person.distanceCm)
                }
            }
        }
    }

    private func arc(_ origin: CGPoint, _ r: Double) -> Path {
        var p = Path()
        p.addArc(center: origin, radius: r, startAngle: .degrees(-160), endAngle: .degrees(-20), clockwise: false)
        return p
    }

    private func sector(_ origin: CGPoint, _ r: Double) -> Path {
        var p = Path()
        p.move(to: origin)
        p.addArc(center: origin, radius: r, startAngle: .degrees(-160), endAngle: .degrees(-20), clockwise: false)
        p.closeSubpath()
        return p
    }
}
