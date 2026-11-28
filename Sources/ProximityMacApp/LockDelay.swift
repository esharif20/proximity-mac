import AppKit
import SwiftUI

/// macOS's own "Require password after screen saver begins or display is turned off". People blamed
/// this app for the Touch ID prompt on return, so Setup and Settings show the delay. The app only
/// reads it; changing it is left to System Settings.
enum LockDelay: Equatable {
    case immediately
    case after(seconds: Int)
    case off

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension")!

    /// `sysadminctl -screenLock status` needs no admin rights. It prints to stderr, for example
    /// "screenLock delay is 300 seconds", "screenLock is immediate" or "screenLock is off".
    static func read() async -> LockDelay? {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/sysadminctl")
            process.arguments = ["-screenLock", "status"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do { try process.run() } catch { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return parse(String(decoding: data, as: UTF8.self))
        }.value
    }

    static func parse(_ output: String) -> LockDelay? {
        let text = output.lowercased()
        if text.contains("immediate") { return .immediately }
        if text.contains("screenlock is off") || text.contains("screenlock is disabled") { return .off }
        guard let range = text.range(of: #"delay is (\d+) seconds"#, options: .regularExpression) else { return nil }
        let digits = text[range].filter(\.isNumber)
        guard let seconds = Int(digits) else { return nil }
        return seconds == 0 ? .immediately : .after(seconds: seconds)
    }

    var line: String {
        switch self {
        case .immediately:
            "macOS asks for your password as soon as the screens turn off."
        case .after(let seconds):
            "macOS asks for your password when the screens have been off longer than \(Self.duration(seconds))."
        case .off:
            "macOS does not ask for your password after the screens turn off."
        }
    }

    static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        let hours = seconds / 3600
        return hours == 1 ? "1 hour" : "\(hours) hours"
    }
}

/// The lock delay line and the button to change it, shared by Setup and Settings.
struct LockDelayNote: View {
    @State private var delay: LockDelay?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Lock Screen settings") { NSWorkspace.shared.open(LockDelay.settingsURL) }
        }
        // Re-read when the app comes back, so a change made in System Settings shows at once.
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    private var text: String {
        if let delay { return delay.line }
        return loaded ? "macOS may ask for your password after the screens have been off a while." : " "
    }

    private func refresh() async {
        delay = await LockDelay.read()
        loaded = true
    }
}
