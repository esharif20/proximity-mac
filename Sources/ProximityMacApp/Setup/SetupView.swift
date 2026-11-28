import SwiftUI
import enum PresenceCore.Command

/// The first-run Setup window. Layout and motion follow docs/design/setup.md.
struct SetupView: View {
    @State private var model: SetupModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(coordinator: Coordinator) {
        _model = State(initialValue: SetupModel(coordinator: coordinator))
    }

    var body: some View {
        HStack(spacing: 0) {
            stage
            SetupPanel(model: model)
                .frame(width: 300)
        }
        .frame(width: 900, height: 580)
        .background(.black)
        .preferredColorScheme(.dark)
        .onAppear { model.open() }
        .onDisappear { model.close() }
    }

    /// The camera fills the stage; the map joins it in the steps that measure the room.
    private var stage: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                VisionStage(frame: model.showsCamera ? model.frame : nil, gazeTargets: gazeTargets)
                    .overlay {
                        if !model.showsCamera { Color.black.opacity(0.6) }
                    }
                if showsMap {
                    VStack(spacing: 10) {
                        RoomMap(person: model.frame?.face.map { ($0.distanceCm, $0.horizontalAngleDeg) },
                                radiusCm: model.radiusCm, counted: model.counted)
                        CountedLabel(counted: model.counted)
                        Slider(value: $model.radiusCm, in: SetupModel.minRadius...SetupModel.maxRadius, step: 5) {
                            Text("Desk radius")
                        }
                        Text("Desk radius \(Int(model.radiusCm)) cm")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(20)
                    .frame(width: 260)
                    .background(Color(white: 0.06))
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(stepAnimation, value: showsMap)
            SetupHUD(frame: model.frame, cpuPercent: model.cpuPercent)
                .padding(14)
        }
    }

    private var showsMap: Bool { model.step == .leanBack || model.step == .bed }

    private var gazeTargets: [GazeTarget: Bool]? {
        guard model.step == .monitors else { return nil }
        let current = model.frame?.face.map { GazeTarget(yawDeg: $0.yawDeg) }
        return Dictionary(uniqueKeysWithValues: GazeTarget.allCases.map { ($0, $0 == current) })
    }

    private var stepAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 1)
    }
}

/// "Counted" inside the desk radius, "Not counted" outside. Not an error, so no red.
struct CountedLabel: View {
    let counted: Bool?

    var body: some View {
        Text(counted == nil ? "No one seen" : counted == true ? "Counted" : "Not counted")
            .font(.headline)
            .foregroundStyle(counted == true ? Color.accentColor : .secondary)
            .contentTransition(.opacity)
            .animation(.easeOut(duration: 0.15), value: counted)
    }
}

/// The glass side panel: step dots, title, one line, the step's controls, then Back and Continue.
private struct SetupPanel: View {
    @Bindable var model: SetupModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepDots(current: model.step.rawValue, count: SetupModel.Step.allCases.count)
                .padding(.bottom, 28)
            ZStack(alignment: .topLeading) {
                content
                    .id(model.step)
                    .transition(transition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 1), value: model.step)
            buttons
        }
        .padding(24)
        .frame(maxHeight: .infinity)
        .background {
            if reduceTransparency { Color(white: 0.1) }
        }
        .glassEffect(reduceTransparency ? .identity : .regular, in: .rect(cornerRadius: 0))
    }

    private var transition: AnyTransition {
        if reduceMotion { return .opacity }
        let edge: Edge = model.direction == .forward ? .trailing : .leading
        return .asymmetric(insertion: .offset(x: edge == .trailing ? 12 : -12).combined(with: .opacity),
                           removal: .offset(x: edge == .trailing ? -12 : 12).combined(with: .opacity))
    }

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2.weight(.semibold))
                .tracking(-0.3)
            Text(line)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            stepControls
                .padding(.top, 8)
        }
    }

    @ViewBuilder private var stepControls: some View {
        switch model.step {
        case .welcome:
            VStack(alignment: .leading, spacing: 10) {
                Label("Camera: to see if you're at your desk.", systemImage: "camera")
                Label("Microphone: to hear \"\(model.coordinator.triggerPhrase), wake up\".", systemImage: "mic")
                Label("Nothing from the camera is saved.", systemImage: "lock")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        case .sit:
            if model.isCalibrating {
                ProgressView().progressViewStyle(.linear)
            } else if model.calibrated {
                Label("Calibrated", systemImage: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
            } else {
                Button("Try again") { model.calibrate() }
            }
        case .leanBack:
            if let farthest = model.farthestCountedCm {
                Text("Farthest: \(Int(farthest)) cm").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
        case .monitors:
            Text(monitorsLine).font(.callout)
        case .bed:
            if let face = model.frame?.face, model.counted == true {
                Button("Shrink the radius to \(Int(max(SetupModel.minRadius, face.distanceCm - SetupModel.radiusMarginCm))) cm") {
                    model.shrinkRadius(below: face.distanceCm)
                }
            }
        case .owner:
            OwnerStep(model: model)
        case .voice:
            VoiceStep(model: model)
        case .done:
            DoneCard(model: model)
        }
    }

    private var monitorsLine: String {
        let seen = GazeTarget.allCases.filter { model.lookedAt.contains($0) }.count
        let still = model.counted == true ? "Still counted." : "Not seen."
        return "\(seen) of 3 looked at. \(still)"
    }

    private var buttons: some View {
        HStack {
            if model.step != .welcome && model.step != .done {
                Button("Back") { model.back() }
                    .buttonStyle(.glass)
            }
            Spacer()
            if model.step == .owner && !model.enrolled {
                Button("Skip") { model.skipOwner() }
                    .buttonStyle(.glass)
            } else if model.step == .done {
                Button("Done") { dismissWindow(id: "setup") }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(model.step == .welcome ? "Allow and continue" : "Continue") { model.next() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.step == .sit && model.isCalibrating)
            }
        }
    }

    private var title: String {
        switch model.step {
        case .welcome: "Welcome"
        case .sit: "Sit normally"
        case .leanBack: "Lean back, then stand behind your chair"
        case .monitors: "Look at each monitor"
        case .bed: "Go to your bed"
        case .owner: "Only wake for me"
        case .voice: "Say \"\(model.coordinator.triggerPhrase), wake up\""
        case .done: "All set"
        }
    }

    private var line: String {
        switch model.step {
        case .welcome: "Proximity Mac turns your screens off when you leave and back on when you return."
        case .sit: "Measuring your face at your normal distance."
        case .leanBack: "The desk radius grows to the farthest place you still count."
        case .monitors: "You still count while looking away from the camera."
        case .bed: "From here you should not count."
        case .owner: "Optional. Only your face wakes the screens, and voice needs your face."
        case .voice: "Try a Command. It does nothing here."
        case .done: "You can run Setup again from the menu."
        }
    }
}

private struct StepDots: View {
    let current: Int
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Color.primary : Color.secondary.opacity(0.35))
                    .frame(width: index == current ? 16 : 6, height: 6)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 1), value: current)
        .accessibilityElement()
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}

private struct OwnerStep: View {
    let model: SetupModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().stroke(.white.opacity(0.12), lineWidth: 5)
                    Circle()
                        .trim(from: 0, to: Double(model.enrolSamples) / Double(SetupModel.enrolTotal))
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1), value: model.enrolSamples)
                    if model.enrolled {
                        Image(systemName: "checkmark").font(.title3.weight(.semibold)).foregroundStyle(Color.accentColor)
                    }
                }
                .frame(width: 52, height: 52)
                if !model.enrolled {
                    Button(model.isEnrolling ? "Hold still…" : "Enrol my face") { model.enrol() }
                        .disabled(model.isEnrolling)
                }
            }
            if model.enrolled {
                @Bindable var coordinator = model.coordinator
                Toggle("Only wake for me", isOn: $coordinator.settings.onlyWakeForMe)
                Toggle("Voice commands need my face", isOn: $coordinator.settings.voiceNeedsMe)
            }
            Text("A Face signature is a short list of numbers, kept only in your Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct VoiceStep: View {
    let model: SetupModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Waveform(level: model.voiceLevel)
                .frame(height: 40)
            HStack(spacing: 8) {
                Text(model.heardWords.map { "\"\($0)\"" } ?? "Listening")
                    .foregroundStyle(model.heardWords == nil ? .secondary : .primary)
                if model.heardCommand != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: model.heardCommand != nil)
        }
    }
}

/// A rolling bar waveform from the RMS level. History lives in the view so the model keeps one number.
private struct Waveform: View {
    let level: Float
    @State private var history = [Float](repeating: 0, count: 32)

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(history.indices, id: \.self) { index in
                Capsule()
                    .fill(Color.accentColor.opacity(0.4 + 0.6 * Double(index) / Double(history.count)))
                    .frame(width: 4, height: max(3, CGFloat(min(1, history[index] * 4)) * 40))
            }
        }
        .onChange(of: level) { _, level in
            history.removeFirst()
            history.append(level)
        }
    }
}

private struct DoneCard: View {
    let model: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RoomMap(person: nil, radiusCm: model.radiusCm, counted: nil)
                .frame(height: 150)
            LabeledContent("Desk radius", value: "\(Int(model.radiusCm)) cm")
                .monospacedDigit()
            Text(model.enrolled ? "Stored: 6 numbers + Face signature in Keychain" : "Stored: 6 numbers")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.white.opacity(0.05), in: .rect(cornerRadius: 12))
    }
}
