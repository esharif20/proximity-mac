import PresenceCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var coordinator: Coordinator
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled
    @State private var confirmingDelete = false
    @State private var phoneSignal = PhoneSignal()

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: $opensAtLogin)
                    .onChange(of: opensAtLogin) { _, on in setOpensAtLogin(on) }
            }
            Section("Presence") {
                Stepper("Check after \(Int(coordinator.settings.idleBeforeCheck)) s idle",
                        value: $coordinator.settings.idleBeforeCheck, in: 10...600, step: 5)
                Stepper("Away after \(Int(coordinator.settings.absenceBeforeAway)) s unseen",
                        value: $coordinator.settings.absenceBeforeAway, in: 10...600, step: 5)
                Stepper("Countdown \(coordinator.settings.graceSeconds) s",
                        value: $coordinator.settings.graceSeconds, in: 3...60)
                Stepper("Desk radius \(Int(coordinator.settings.deskRadiusCm)) cm",
                        value: $coordinator.settings.deskRadiusCm, in: 40...300, step: 10)
                Stepper("Stop watching after \(Int(coordinator.settings.stopWatchingAfterMinutes)) min away",
                        value: $coordinator.settings.stopWatchingAfterMinutes, in: 5...240, step: 5)
                Toggle("Lock when away", isOn: $coordinator.settings.lockWhenAway)
                LockDelayNote()
            }
            Section("Away") {
                Toggle("Keep the MacBook screen on while away (Monitors Off)", isOn: $coordinator.settings.keepBuiltInOn)
                Toggle("Keep screens on while a video is playing", isOn: $coordinator.settings.respectMediaPlaying)
            }
            Section("Phone or watch") {
                if let phone = coordinator.settings.phone {
                    LabeledContent("Device", value: phone.name)
                    LabeledContent("Signal now") {
                        HStack(spacing: 8) {
                            Text(phoneSignal.rssi.map { "\(Int($0.rounded())) dBm" } ?? "Not heard")
                                .monospacedDigit()
                                .contentTransition(.numericText())
                            SignalBars(rssi: phoneSignal.rssi)
                        }
                    }
                    Text("At the desk \(Int(phone.nearRssi.rounded())) dBm, far away \(Int(phone.farRssi.rounded())) dBm.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    HStack {
                        Spacer()
                        Button("Forget", role: .destructive) { coordinator.settings.phone = nil }
                    }
                } else {
                    Text("Link your phone or watch in Setup, so its signal helps tell when you've left.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open Setup") { coordinator.openSetup() }
                }
            }
            .onChange(of: coordinator.settings.phone?.identifier, initial: true) { _, identifier in
                phoneSignal.listen(to: identifier)
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
            Section("Owner") {
                Toggle("Only wake for me", isOn: $coordinator.settings.onlyWakeForMe)
                    .disabled(!coordinator.hasFaceSignature)
                Toggle("Voice commands need my face", isOn: $coordinator.settings.voiceNeedsMe)
                    .disabled(!coordinator.hasFaceSignature)
                Text(coordinator.hasFaceSignature
                     ? "Your face signature is saved in the Keychain on this Mac. Typing always wakes the screens."
                     : "Enrol your face to turn these on. Only numbers are saved, never a picture.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(coordinator.hasFaceSignature ? "Re-enrol my face" : "Enrol my face") { coordinator.openSetup() }
                    Spacer()
                    Button("Delete my face signature", role: .destructive) { confirmingDelete = true }
                        .disabled(!coordinator.hasFaceSignature)
                }
            }
            .confirmationDialog("Delete your face signature?", isPresented: $confirmingDelete) {
                Button("Delete", role: .destructive) { coordinator.deleteFaceSignature() }
            } message: {
                Text("Only wake for me and Voice commands need my face turn off. You can enrol again later.")
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
        .onDisappear {
            coordinator.setPreviewing(false)
            phoneSignal.listen(to: nil)
        }
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func setOpensAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            // Registration fails outside a bundled app (for example `swift run`); show the real state.
        }
        let actual = SMAppService.mainApp.status == .enabled
        if actual != opensAtLogin { opensAtLogin = actual }
    }
}
