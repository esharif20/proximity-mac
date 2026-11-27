import AppKit
import SwiftUI

/// The Grace countdown on every screen. Panels are click-through and never become key, so the
/// person's typing and focus stay exactly where they were.
@MainActor
final class GraceOverlay {
    private var panels: [NSPanel] = []
    private var content: (() -> AnyView)?
    private var screenObserver: (any NSObjectProtocol)?

    init() {
        // A display plugged in or out mid-countdown still gets the notice.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
    }

    var isShowing: Bool { content != nil }

    func show(_ view: some View) {
        content = { AnyView(view) }
        rebuild()
    }

    func hide() {
        content = nil
        panels.forEach { $0.orderOut(nil) }
        panels = []
    }

    private func rebuild() {
        panels.forEach { $0.orderOut(nil) }
        panels = []
        guard let content else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for screen in NSScreen.screens {
            let panel = Self.makePanel(on: screen, content: content())
            if reduceMotion {
                panel.orderFrontRegardless()
            } else {
                panel.alphaValue = 0
                panel.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().alphaValue = 1
                }
            }
            panels.append(panel)
        }
    }

    private static func makePanel(on screen: NSScreen, content: AnyView) -> NSPanel {
        let size = CGSize(width: 560, height: 88)
        let visible = screen.visibleFrame
        let origin = CGPoint(x: visible.midX - size.width / 2, y: visible.minY + visible.height * 0.18)
        let panel = NSPanel(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: content.frame(width: size.width, height: size.height))
        return panel
    }
}

struct GraceNotice: View {
    let coordinator: Coordinator

    var body: some View {
        let seconds = StatusText.secondsLeft(coordinator.graceUntil ?? coordinator.now, coordinator.now)
        VStack(spacing: 4) {
            Text("Screens off in \(seconds) s")
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText(countsDown: true))
            Text("Move the mouse or say \u{201C}\(coordinator.triggerPhrase), keep it on\u{201D}.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .combine)
        .transaction { if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { $0.animation = nil } }
    }
}
