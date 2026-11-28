import AppKit
import PresenceSensors
import SwiftUI

/// Monitors Off (ADR 0005): a black window over every external display, on top of the zero gamma
/// `DisplayControl` sets, so even a monitor that ignores gamma shows black with no menu bar or Dock.
/// The built-in display shows the Away screen instead. The windows ignore the mouse and never become
/// key, so focus stays where the person left it.
///
/// If the app crashes, macOS removes its windows and restores gamma when the process exits, so the
/// monitors cannot stay dark.
@MainActor
final class MonitorsOff {
    private let display: DisplayControl
    private var panels: [NSPanel] = []
    private var observers: [any NSObjectProtocol] = []
    private var inputMonitor: Any?
    private let away = AwayModel()
    private var glowTask: Task<Void, Never>?
    /// When the last glow finished dimming. Measured from the end so the light change itself,
    /// which the camera sees as motion, cannot start the next one.
    private var lastGlowEnd = -Double.infinity
    /// In clamshell mode every display is black and there is nothing to light.
    private var showsAwayScreen = false
    /// Called on any mouse movement or click while showing, so the engine hears about input
    /// without waiting for the next one-second tick.
    var onInput: (() -> Void)?

    init(display: DisplayControl) {
        self.display = display
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        })
        observers.append(center.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        })
    }

    private(set) var isShowing = false

    func show() {
        guard !isShowing else { return }
        isShowing = true
        rebuild()
        // Mouse events need no permission; key presses reach the engine through idle time anyway.
        inputMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onInput?() }
        }
    }

    /// Lights the Away screen warm white for about 2 s, at most once every 5 s.
    func glow(at now: Double) {
        guard isShowing, !away.glowing, now - lastGlowEnd >= Self.glowGap,
              showsAwayScreen else { return }
        away.glowing = true
        glowTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.glowSeconds))
            guard !Task.isCancelled, let self else { return }
            self.away.glowing = false
            self.lastGlowEnd = ProcessInfo.processInfo.systemUptime
        }
    }

    static let glowSeconds = 2.0
    static let glowGap = 5.0

    /// Removes the windows and restores gamma. Safe to call when nothing is showing.
    func hide() {
        glowTask?.cancel()
        glowTask = nil
        away.glowing = false
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        inputMonitor = nil
        isShowing = false
        panels.forEach { $0.orderOut(nil) }
        panels = []
        showsAwayScreen = false
        display.restore()
    }

    private func screensChanged() {
        guard isShowing else { return }
        rebuild()
        display.displaysChanged()
    }

    private func rebuild() {
        panels.forEach { $0.orderOut(nil) }
        panels = []
        showsAwayScreen = NSScreen.screens.contains(where: \.isBuiltIn)
        for screen in NSScreen.screens {
            let panel = Self.makePanel(on: screen)
            panel.contentView = screen.isBuiltIn
                ? NSHostingView(rootView: AwayScreen(model: away))
                : NSHostingView(rootView: Color.black.ignoresSafeArea())
            panel.orderFrontRegardless()
            panels.append(panel)
        }
    }

    static func makePanel(on screen: NSScreen) -> NSPanel {
        let panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.isOpaque = true
        panel.backgroundColor = .black
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.setFrame(screen.frame, display: false)
        return panel
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    var isBuiltIn: Bool {
        guard let displayID else { return false }
        return CGDisplayIsBuiltin(displayID) != 0
    }
}
