import AppKit
import Observation
import enum PresenceCore.PresenceState

/// The menu bar glyph: a small monitor drawn in code, so it matches the menu bar in light and dark
/// and stays crisp at any scale.
///
/// The image changes only when the state or the listening flag changes, and every state has a still glyph.
/// No timer animates it: each new image re-renders the status item on every menu bar, and a 0.4 s Checking
/// pulse alone cost about 6% CPU (docs/spikes/camera-cost.md).
@MainActor @Observable
final class MenuBarIcon {
    private(set) var image: NSImage

    @ObservationIgnored private var glyph: Glyph

    init() {
        glyph = Glyph(kind: .off, listening: false)
        image = Self.render(glyph)
    }

    /// Call when the state, the listening flag or the Grace length changes. The Grace length no longer
    /// changes the glyph; it stays in the call so the Coordinator is unchanged.
    func show(_ state: PresenceState, listening: Bool, graceSeconds _: Int) {
        let next = Glyph(kind: Glyph.Kind(state), listening: listening)
        guard next != glyph else { return }
        glyph = next
        image = Self.render(next)
    }
}

/// What the icon shows, independent of how it is drawn.
struct Glyph: Equatable {
    enum Kind: Equatable {
        case off, present, checking, grace, away, hold

        init(_ state: PresenceState) {
            switch state {
            case .off: self = .off
            case .present: self = .present
            case .checking: self = .checking
            case .grace: self = .grace
            case .away: self = .away
            case .hold: self = .hold
            }
        }
    }

    var kind: Kind
    var listening: Bool
}

extension MenuBarIcon {
    static let height: CGFloat = 18
    static let monitorWidth: CGFloat = 18
    static let wavesWidth: CGFloat = 7

    /// A template image takes the menu bar's own colour; alpha gives the two tones (outline and lit screen).
    static func render(_ glyph: Glyph) -> NSImage {
        let width = monitorWidth + (glyph.listening ? wavesWidth : 0)
        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(glyph, in: context)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func draw(_ glyph: Glyph, in context: CGContext) {
        let ink = CGColor(gray: 0, alpha: 1)
        context.setStrokeColor(ink)
        context.setFillColor(ink)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        let screen = CGRect(x: 1.75, y: 2.75, width: 14.5, height: 10)
        let inner = screen.insetBy(dx: 1.5, dy: 1.5)
        let outline = CGPath(roundedRect: screen, cornerWidth: 2, cornerHeight: 2, transform: nil)

        // Lit screen: a soft fill inside the outline.
        switch glyph.kind {
        case .present, .checking, .hold:
            fill(inner, alpha: 0.35, in: context)
        case .grace:
            // The lower half lit: the screen is on its way out. The countdown itself is on the overlay.
            let lit = inner.height / 2
            fill(CGRect(x: inner.minX, y: inner.maxY - lit, width: inner.width, height: lit), alpha: 0.35, in: context)
        case .away, .off:
            break
        }

        context.setLineWidth(1.5)
        context.addPath(outline)
        context.strokePath()
        // Stand: a short neck and a base.
        context.move(to: CGPoint(x: 9, y: 13.5))
        context.addLine(to: CGPoint(x: 9, y: 15.25))
        context.move(to: CGPoint(x: 6, y: 15.75))
        context.addLine(to: CGPoint(x: 12, y: 15.75))
        context.strokePath()

        let centre = CGPoint(x: screen.midX, y: screen.midY)
        switch glyph.kind {
        case .present:
            dot(at: centre, radius: 1.75, alpha: 1, in: context)
        case .checking:
            // Smaller and dimmer than Present's dot: looking, not yet sure.
            dot(at: centre, radius: 1.4, alpha: 0.5, in: context)
        case .hold:
            pin(at: centre, in: context)
        case .off:
            strike(screen, in: context)
        case .grace, .away:
            break
        }

        if glyph.listening { waves(from: CGPoint(x: monitorWidth - 0.5, y: centre.y), in: context) }
    }

    private static func fill(_ rect: CGRect, alpha: CGFloat, in context: CGContext) {
        guard rect.height > 0 else { return }
        context.saveGState()
        context.setAlpha(alpha)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 0.75, cornerHeight: 0.75, transform: nil))
        context.fillPath()
        context.restoreGState()
    }

    private static func dot(at centre: CGPoint, radius: CGFloat, alpha: CGFloat, in context: CGContext) {
        context.saveGState()
        context.setAlpha(alpha)
        context.fillEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
        context.restoreGState()
    }

    private static func pin(at centre: CGPoint, in context: CGContext) {
        // Tilted, so it reads as a push pin and not a keyhole.
        let head = CGPoint(x: centre.x + 1.4, y: centre.y - 1.3)
        context.setLineWidth(1.2)
        context.move(to: head)
        context.addLine(to: CGPoint(x: centre.x - 2.2, y: centre.y + 2.4))
        context.strokePath()
        context.fillEllipse(in: CGRect(x: head.x - 1.8, y: head.y - 1.8, width: 3.6, height: 3.6))
    }

    private static func strike(_ screen: CGRect, in context: CGContext) {
        let from = CGPoint(x: screen.minX - 0.5, y: screen.maxY + 3)
        let to = CGPoint(x: screen.maxX + 0.5, y: screen.minY - 1.5)
        // Cut a gap around the line first so it reads as a slash over the outline, not a tangle.
        context.saveGState()
        context.setBlendMode(.clear)
        context.setLineWidth(3.5)
        context.move(to: from)
        context.addLine(to: to)
        context.strokePath()
        context.restoreGState()
        context.setLineWidth(1.5)
        context.move(to: from)
        context.addLine(to: to)
        context.strokePath()
    }

    private static func waves(from origin: CGPoint, in context: CGContext) {
        context.setLineWidth(1.3)
        for (radius, alpha) in [(2.5, 1.0), (5.0, 0.6)] {
            context.saveGState()
            context.setAlpha(alpha)
            context.addArc(center: origin, radius: radius, startAngle: -.pi / 3.2, endAngle: .pi / 3.2, clockwise: false)
            context.strokePath()
            context.restoreGState()
        }
    }
}
