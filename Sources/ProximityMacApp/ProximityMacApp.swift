import PresenceCore
import PresenceSensors
import SwiftUI

@main
struct ProximityMacApp: App {
    var body: some Scene {
        MenuBarExtra("Proximity Mac", systemImage: "person.crop.circle") {
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }
}
