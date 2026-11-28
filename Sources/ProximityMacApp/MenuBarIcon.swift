import AppKit
import Observation
import enum PresenceCore.PresenceState

/// The menu bar glyph: a small monitor drawn in code, so it matches the menu bar in light and dark
/// and stays crisp at any scale.
///
/// The image changes only when what it shows changes. While Present nothing here runs, so the menu
/// bar is not redrawn and the active mode stays near zero CPU. The only timers are the Checking pulse
/// and the Grace drain, and both stop as soon as the state moves on.
@MainActor @Observable
final class MenuBarIcon {
    private(set) var image: NSImage

    @ObservationIgnored private var glyph: Glyph
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var transitionStart: Double?
    @ObservationIgnored private var previous: Glyph?

    init() {
        glyph = Glyph(kind: .off, listening: false)
        image = Self.render(glyph, blendingFrom: nil, progress: 1)
    }

    /// Call when the state, the listening flag or the Grace length changes.
    func show(_ state: PresenceState, listening: Bool, graceSeconds: Int) {
        var next = Glyph(kind: Glyph.Kind(state), listening: listening)
        if case .grace(let until) = state {
            next.graceUntil = until
            next.graceSeconds = Double(max(1, graceSeconds))
        }
        guard next != glyph else { return }
        let changedShape = next.kind != glyph.kind || next.listening != glyph.listening
        previous = changedShape && !reduceMotion ? glyph : nil
        transitionStart = previous == nil ? nil : now
        glyph = next
        redraw()
        schedule()
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var now: Double { ProcessInfo.processInfo.systemUptime }

    private func redraw() {
        var frame = glyph
        let t = now
        if glyph.kind == .checking, !reduceMotion {
            // A slow breath: about 2.4 s per cycle, eased so it never snaps.
            let phase = (t.truncatingRemainder(dividingBy: Self.pulsePeriod)) / Self.pulsePeriod
            frame.pulse = 0.5 - 0.5 * cos(phase * 2 * .pi)
        }
        if let until = glyph.graceUntil, let total = glyph.graceSeconds {
            frame.drain = min(1, max(0, (until - t) / total))
        }
        var progress = 1.0
        if let start = transitionStart {
            progress = min(1, (t - start) / Self.transitionDuration)
            if progress >= 1 { transitionStart = nil; previous = nil }
        }
        image = Self.render(frame, blendingFrom: previous, progress: easeOut(progress))
    }

    /// Runs a timer only while something on the icon is moving, at the lowest rate that still reads
    /// as motion at 18 pt.
    private func schedule() {
        timer?.invalidate()
        timer = nil
        let interval: Double? = if transitionStart != nil {
            1.0 / 30
        } else if glyph.kind == .checking, !reduceMotion {
            Self.pulsePeriod / 6
        } else if glyph.kind == .grace {
            0.5
        } else {
            nil
        }
        guard let interval else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func step() {
        let wasTransitioning = transitionStart != nil
        redraw()
        // The transition's fast timer hands over to the state's own rate once it settles.
        if wasTransitioning, transitionStart == nil { schedule() }
    }

    private func easeOut(_ t: Double) -> Double { 1 - pow(1 - t, 3) }

    static let pulsePeriod = 2.4
    static let transitionDuration = 0.18
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
    var graceUntil: Double?
    var graceSeconds: Double?
    /// 0 to 1, the Checking dot's breath. 1 when not pulsing.
    var pulse = 1.0
    /// 0 to 1, how much of the Grace countdown is left.
    var drain = 1.0
}

extension MenuBarIcon {
    static let height: CGFloat = 18
    static let monitorWidth: CGFloat = 18
    static let wavesWidth: CGFloat = 7

    /// Draws one frame. A template image takes the menu bar's own colour; alpha gives the two tones
    /// (outline and lit screen).
    static func render(_ glyph: Glyph, blendingFrom old: Glyph?, progress: Double) -> NSImage {
        let listening = glyph.listening || (old?.listening ?? false)
        let width = monitorWidth + (listening ? wavesWidth : 0)
        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            if let old, progress < 1 {
                context.saveGState()
                context.setAlpha(1 - progress)
                draw(old, in: context)
                context.restoreGState()
                context.setAlpha(progress)
            }
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
            // Drains from the top down, like a level falling.
            let lit = inner.height * glyph.drain
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
            dot(at: centre, radius: 1.4 + 0.45 * glyph.pulse, alpha: 0.45 + 0.55 * glyph.pulse, in: context)
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
