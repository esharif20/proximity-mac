import PresenceCore
import SwiftUI

struct SettingsView: View {
    @Bindable var coordinator: Coordinator

    var body: some View {
        Form {
            Section("Presence") {
                Stepper("Check after \(Int(coordinator.settings.idleBeforeCheck)) s idle",
                        value: $coordinator.settings.idleBeforeCheck, in: 10...600, step: 5)
                Stepper("Away after \(Int(coordinator.settings.absenceBeforeAway)) s unseen",
                        value: $coordinator.settings.absenceBeforeAway, in: 10...600, step: 5)
                Stepper("Countdown \(coordinator.settings.graceSeconds) s",
                        value: $coordinator.settings.graceSeconds, in: 3...60)
                Stepper("Desk radius \(Int(coordinator.settings.deskRadiusCm)) cm",
                        value: $coordinator.settings.deskRadiusCm, in: 40...300, step: 10)
                Toggle("Lock when away", isOn: $coordinator.settings.lockWhenAway)
            }
            Section("Distance") {
                LabeledContent("Distance now", value: coordinator.lastDistanceCm.map { "\(Int($0.rounded())) cm" } ?? "Not seen")
                    .monospacedDigit()
                LabeledContent("Calibration", value: coordinator.settings.calibration == nil ? "Not calibrated" : "Calibrated")
                HStack {
                    Button("Calibrate: sit normally") { Task { await coordinator.calibrate() } }
                        .disabled(coordinator.isCalibrating)
                    if coordinator.isCalibrating { ProgressView().controlSize(.small) }
                }
            }
            Section("Wake up") {
                Picker("\"Wake up\" keeps screens on", selection: $coordinator.settings.wakeUpMode) {
                    Text("Until \"go to sleep\" or back at the desk").tag(WakeUpMode.untilSleepOrDesk)
                    Text("For a set time").tag(WakeUpMode.timedHold)
                }
                if coordinator.settings.wakeUpMode == .timedHold {
                    Stepper("For \(coordinator.settings.wakeUpHoldMinutes) min",
                            value: $coordinator.settings.wakeUpHoldMinutes, in: 5...240, step: 5)
                }
            }
            Section("Voice") {
                Toggle("Listen for commands", isOn: $coordinator.settings.voiceEnabled)
                TextField("Trigger word", text: $coordinator.settings.triggerWord)
                    .disabled(!coordinator.settings.voiceEnabled)
            }
            Section("Feature log") {
                Toggle("Keep a feature log (numbers only)", isOn: $coordinator.isLogging)
                Text("Saved on this Mac in Application Support. Never frames, sound or words.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { coordinator.setPreviewing(true) }
        .onDisappear { coordinator.setPreviewing(false) }
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}
