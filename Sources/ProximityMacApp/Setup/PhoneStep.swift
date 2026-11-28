import Observation
import SwiftUI
import class PresenceSensors.BLESource
import struct PresenceSensors.FoundDevice

/// Setup's optional phone or watch step: pick the device, then measure its signal at the desk and far away.
struct PhoneStep: View {
    let model: SetupModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let device = model.chosenDevice {
                measuring(device)
            } else {
                picking
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.3, dampingFraction: 1),
                   value: model.chosenDevice?.id)
    }

    // MARK: Picking

    private var picking: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.devices.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for devices").foregroundStyle(.secondary)
                }
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.devices) { device in
                            DeviceRow(device: device) { model.choose(device) }
                        }
                    }
                }
                .frame(maxHeight: 220)
                .scrollBounceBehavior(.basedOnSize)
            }
            Text("Bring it close to the Mac: yours has the strongest signal.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Measuring

    private func measuring(_ device: FoundDevice) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "iphone")
                    .foregroundStyle(.secondary)
                Text(device.name).lineLimit(1)
                Spacer()
                SignalBars(rssi: model.phoneSignal)
            }
            .padding(10)
            .background(.white.opacity(0.06), in: .rect(cornerRadius: 10))

            MeasureRow(label: "At the desk", rssi: model.nearRssi)
            MeasureRow(label: "Far away", rssi: model.farRssi)

            instruction
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                action
                if model.isMeasuringPhone { ProgressView().controlSize(.small) }
                Spacer()
                Button("Choose another") { model.chooseAnotherDevice() }
                    .buttonStyle(.link)
                    .disabled(model.isMeasuringPhone)
            }
        }
    }

    @ViewBuilder private var instruction: some View {
        if model.phoneNotHeard {
            Text("Nothing heard from it. Wake its screen and try again.")
                .foregroundStyle(.orange)
        } else if model.phoneGapTooSmall {
            Text("The signal can't tell the desk from there. Try the door, or a spot farther away.")
                .foregroundStyle(.orange)
        } else if model.phoneLinked {
            Label("Linked", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color.accentColor)
        } else if model.nearRssi == nil {
            Text("Hold it at the desk.")
        } else {
            Text("Now take it to your bed or the door.")
        }
    }

    @ViewBuilder private var action: some View {
        if model.nearRssi == nil {
            Button(model.isMeasuringPhone ? "Measuring…" : "Measure at the desk") { model.measurePhone(near: true) }
                .disabled(model.isMeasuringPhone)
        } else if model.farRssi == nil || model.phoneGapTooSmall {
            Button(model.isMeasuringPhone ? "Measuring…" : "Measure here") { model.measurePhone(near: false) }
                .disabled(model.isMeasuringPhone)
        } else {
            Button("Measure again") { model.measurePhone(near: true) }
        }
    }
}

private struct DeviceRow: View {
    let device: FoundDevice
    let choose: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 10) {
                Text(device.name).lineLimit(1)
                Spacer()
                SignalBars(rssi: device.rssi)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(.rect)
            .background(.white.opacity(hovering ? 0.08 : 0), in: .rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel("\(device.name), \(SignalBars.description(device.rssi))")
    }
}

private struct MeasureRow: View {
    let label: String
    let rssi: Double?

    var body: some View {
        LabeledContent(label, value: rssi.map { "\(Int($0.rounded())) dBm" } ?? "Not measured")
            .font(.callout.monospacedDigit())
            .foregroundStyle(rssi == nil ? .secondary : .primary)
            .contentTransition(.numericText())
    }
}

/// Four bars for a Bluetooth signal in dBm. Shared with Settings.
struct SignalBars: View {
    let rssi: Double?

    /// Bars lit for a signal; thresholds in dBm, strongest first.
    static func bars(_ rssi: Double?) -> Int {
        guard let rssi else { return 0 }
        return [-55.0, -65, -75, -85].filter { rssi >= $0 }.count
    }

    static func description(_ rssi: Double?) -> String {
        rssi == nil ? "no signal" : "\(bars(rssi)) of 4 bars"
    }

    var body: some View {
        let lit = Self.bars(rssi)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(index < lit ? Color.primary : Color.secondary.opacity(0.3))
                    .frame(width: 3, height: 4 + CGFloat(index) * 3)
            }
        }
        .animation(.easeOut(duration: 0.2), value: lit)
        .accessibilityElement()
        .accessibilityLabel(Self.description(rssi))
    }
}

/// The linked device's signal while Settings is open, from its own BLESource so the readout does not
/// depend on the engine's sampling mode.
@MainActor @Observable
final class PhoneSignal {
    private(set) var rssi: Double?
    @ObservationIgnored private var source: BLESource?

    /// Starts listening to `identifier`, or stops with nil. Bluetooth is touched only when a device is linked.
    func listen(to identifier: String?) {
        rssi = nil
        guard let identifier else {
            source?.setMode(.off)
            return
        }
        let source = self.source ?? BLESource()
        self.source = source
        source.onObservation { [weak self] observation in
            Task { @MainActor in self?.rssi = observation.rssi }
        }
        source.identifier = identifier
        source.setMode(.checking)
    }
}
