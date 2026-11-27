import AppKit
import PresenceCore
import PresenceSensors
import SwiftUI

@main
struct ProximityMacApp: App {
    @State private var coordinator = Coordinator()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(coordinator: coordinator)
        } label: {
            Image(systemName: StatusText.symbol(coordinator.state))
                .accessibilityLabel("Proximity Mac: \(StatusText.line(coordinator.state, now: coordinator.now))")
        }

        Window("Proximity Mac Settings", id: "settings") {
            SettingsView(coordinator: coordinator)
        }
        .windowResizability(.contentSize)
    }
}

private struct MenuContent: View {
    @Bindable var coordinator: Coordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(StatusText.line(coordinator.state, now: coordinator.now))
        Toggle("On", isOn: $coordinator.isEnabled)
        if coordinator.isLogging {
            Button("That was wrong") { coordinator.markWrong() }
        }
        Divider()
        Button("Settings…") {
            // A menu bar app is never frontmost on its own, so bring it forward or the window opens behind.
            NSApplication.shared.activate()
            openWindow(id: "settings")
        }
        .keyboardShortcut(",")
        Button("Quit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
