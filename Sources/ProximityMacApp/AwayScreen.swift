import AppKit
import Observation
import SwiftUI

/// What the Away screen shows that changes while it is up.
@MainActor @Observable
final class AwayModel {
    /// The panel is lit warm white so the camera can see a face in a dim room.
    var glowing = false
}

/// The built-in display during Monitors Off: nearly black and still, with a small clock.
struct AwayScreen: View {
    let model: AwayModel

    /// A warm white, kinder to eyes adjusted to the dark than pure white.
    private static let glow = Color(red: 1, green: 0.93, blue: 0.82)

    var body: some View {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        ZStack {
            Color.black
            Self.glow.opacity(model.glowing ? 0.9 : 0)
            TimelineView(.everyMinute) { context in
                VStack(spacing: 10) {
                    Text(context.date, format: .dateTime.hour().minute())
                        .font(.system(size: 44, weight: .light))
                        .tracking(-0.5)
                        .monospacedDigit()
                    Text("Monitors off \u{00B7} your Mac is still running")
                        .font(.callout)
                }
                .foregroundStyle(.white.opacity(model.glowing ? 0 : 0.28))
                .offset(Self.drift(at: context.date))
            }
        }
        .ignoresSafeArea()
        // Lighting up is quick so the camera gets its frame; dimming is slower so it does not jolt.
        .animation(reduceMotion ? nil : .easeOut(duration: model.glowing ? 0.4 : 0.9), value: model.glowing)
        .accessibilityElement(children: .combine)
    }

    /// A different spot within 12 pt of centre each minute, so nothing static sits on the panel all night.
    static func drift(at date: Date) -> CGSize {
        let minute = Int(date.timeIntervalSinceReferenceDate / 60)
        // Two cheap integer hashes give a scattered but repeatable position per minute.
        let x = (minute &* 7_919) % 25 - 12
        let y = (minute &* 104_729 &+ 13) % 25 - 12
        return CGSize(width: x, height: y)
    }
}
