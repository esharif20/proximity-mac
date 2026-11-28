@preconcurrency import AVFoundation
import Foundation
import Speech
import Synchronization

/// Listens on the default input and hands final transcripts to the handler.
///
/// Recognition runs on device through SpeechAnalyzer, and only on audio the energy gate lets through.
/// Audio and transcripts stay in memory: nothing here writes to disk or logs.
public final class VoiceSource: VoiceListening {
    /// How a listening session is opened, as closures so tests can run every start and stop path without a microphone.
    struct Opener: Sendable {
        typealias Close = @Sendable () -> Void
        var requestAccess: @Sendable () async -> Bool
        /// Opens the input. Setup must give up without opening it once `isCurrent()` is false (after `stop()`).
        /// `onInterrupted` fires when the input device changes and the engine has stopped itself.
        /// `levelHandler` is read per buffer, so the level is only computed while someone listens for it.
        var open: @Sendable (
            _ isCurrent: @escaping @Sendable () -> Bool,
            _ onText: @escaping @Sendable (String) -> Void,
            _ onInterrupted: @escaping @Sendable () -> Void,
            _ levelHandler: @escaping @Sendable () -> (@Sendable (Float) -> Void)?
        ) async throws -> Close

        static let live = Opener(
            requestAccess: { await AVCaptureDevice.requestAccess(for: .audio) },
            open: { isCurrent, onText, onInterrupted, levelHandler in
                let session = try await VoiceSession.make(
                    isCurrent: isCurrent, onText: onText, onInterrupted: onInterrupted, levelHandler: levelHandler)
                return { session.close() }
            })
    }

    private struct State {
        var running = false
        /// Bumped by every start and stop, so a slow setup that finishes after `stop()` tears itself down.
        var generation = 0
        var setup: Task<Void, Never>?
        var close: Opener.Close?
        var handler: (@Sendable (String) -> Void)?
        var levelHandler: (@Sendable (Float) -> Void)?
    }

    private let state = Mutex(State())
    private let opener: Opener

    public convenience init() {
        self.init(opener: .live)
    }

    init(opener: Opener) {
        self.opener = opener
    }

    deinit {
        // The engine's tap keeps the session alive on its own, so without this the mic would stay on.
        stop()
    }

    var isRunning: Bool { state.withLock { $0.running } }

    public func onTranscript(_ handler: @escaping @Sendable (String) -> Void) {
        state.withLock { $0.handler = handler }
    }

    /// Live input level for the Setup waveform: RMS of each audio buffer, 0...1, only while started.
    public func onLevel(_ handler: @escaping @Sendable (Float) -> Void) {
        state.withLock { $0.levelHandler = handler }
    }

    public func start() {
        state.withLock { s in
            guard !s.running else { return }
            s.running = true
            s.generation += 1
            let generation = s.generation
            s.setup = Task { [weak self] in await self?.setUp(generation) }
        }
    }

    public func stop() {
        let (setup, close) = state.withLock { s -> (Task<Void, Never>?, Opener.Close?) in
            s.running = false
            s.generation += 1
            defer {
                s.setup = nil
                s.close = nil
            }
            return (s.setup, s.close)
        }
        setup?.cancel()
        close?()
    }

    private func setUp(_ generation: Int) async {
        guard await opener.requestAccess(), isCurrent(generation) else {
            // Denied: clear `running` so a later `start()`, after the person allows the mic, tries again.
            finish(generation)
            return
        }
        let close: Opener.Close
        do {
            close = try await opener.open(
                { [weak self] in self?.isCurrent(generation) ?? false },
                { [weak self] text in self?.deliver(text) },
                { [weak self] in self?.restart(after: generation) },
                { [weak self] in self?.levelHandler(generation) })
        } catch {
            finish(generation)
            return
        }
        let kept = state.withLock { s -> Bool in
            guard s.running, s.generation == generation else { return false }
            s.close = close
            s.setup = nil
            return true
        }
        if !kept { close() }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        state.withLock { $0.running && $0.generation == generation }
    }

    private func levelHandler(_ generation: Int) -> (@Sendable (Float) -> Void)? {
        state.withLock { $0.running && $0.generation == generation ? $0.levelHandler : nil }
    }

    /// Root mean square of a whole buffer, clamped to 0...1 for drawing.
    static func level(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return min(1, (sum / Float(samples.count)).squareRoot())
    }

    private func finish(_ generation: Int) {
        state.withLock { s in
            guard s.generation == generation else { return }
            s.running = false
            s.setup = nil
        }
    }

    /// A new default input (headset plugged in, or changed in Sound settings): reopen on it.
    private func restart(after generation: Int) {
        guard isCurrent(generation) else { return }
        stop()
        start()
    }

    private func deliver(_ text: String) {
        let handler = state.withLock { $0.handler }
        handler?(text)
    }
}

enum VoiceError: Error {
    case unsupportedLocale
    case noAudioFormat
    /// `stop()` came first while setup was still running.
    case stopped
}

/// One open microphone plus one analyzer. Everything is created together and released together.
///
/// `@unchecked Sendable`: the engine and converter are touched only from `make`, the tap thread and
/// `close`; the gate only from the tap thread, which AVAudioEngine calls serially; the analyzer is an actor.
final class VoiceSession: @unchecked Sendable {
    private let engine: AVAudioEngine
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let results: Task<Void, Never>
    private var gate = EnergyGate<AVAudioPCMBuffer>()
    private let windowFrames: Int
    private let levelHandler: @Sendable () -> (@Sendable (Float) -> Void)?
    private var configurationObserver: NSObjectProtocol?

    private init(
        engine: AVAudioEngine, converter: AVAudioConverter, outputFormat: AVAudioFormat,
        analyzer: SpeechAnalyzer, input: AsyncStream<AnalyzerInput>.Continuation, results: Task<Void, Never>,
        levelHandler: @escaping @Sendable () -> (@Sendable (Float) -> Void)?
    ) {
        self.levelHandler = levelHandler
        self.engine = engine
        self.converter = converter
        self.outputFormat = outputFormat
        self.analyzer = analyzer
        self.input = input
        self.results = results
        self.windowFrames = max(1, Int(converter.inputFormat.sampleRate * 0.03))
    }

    static func make(
        isCurrent: @escaping @Sendable () -> Bool,
        onText: @escaping @Sendable (String) -> Void,
        onInterrupted: @escaping @Sendable () -> Void,
        levelHandler: @escaping @Sendable () -> (@Sendable (Float) -> Void)?
    ) async throws -> VoiceSession {
        // Every await below can outlast a `stop()`, and the mic must never open after one.
        func checkCurrent() throws { if !isCurrent() { throw VoiceError.stopped } }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
            throw VoiceError.unsupportedLocale
        }
        try checkCurrent()
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        // The on-device model is a system asset the OS fetches once if this locale is missing. This only
        // runs from `start()`, which the engine asks for only when the person has voice on, never at launch.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        try checkCurrent()
        let engine = AVAudioEngine()
        // The default input buffer is about 10 ms, so the IO thread wakes about 100 times a second. A
        // Command is seconds long, so 4096-frame buffers (about 85 ms) lose nothing and wake far less.
        // The HAL applies this to our client only, not to other apps using the same device.
        if let unit = engine.inputNode.audioUnit {
            var frames = UInt32(4096)
            AudioUnitSetProperty(
                unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0,
                &frames, UInt32(MemoryLayout<UInt32>.size))
        }
        let hardwareFormat = engine.inputNode.outputFormat(forBus: 0)
        guard
            let format = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [transcriber], considering: hardwareFormat),
            let converter = AVAudioConverter(from: hardwareFormat, to: format)
        else { throw VoiceError.noAudioFormat }
        try checkCurrent()

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: stream)
        let results = Task {
            do {
                for try await result in transcriber.results where result.isFinal {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { onText(text) }
                }
            } catch {}
        }

        let session = VoiceSession(
            engine: engine, converter: converter, outputFormat: format,
            analyzer: analyzer, input: continuation, results: results, levelHandler: levelHandler)
        guard isCurrent() else {
            session.close()
            throw VoiceError.stopped
        }
        // AVAudioEngine stops itself when the input device changes, so the owner reopens on the new one.
        session.configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { _ in onInterrupted() }
        let bufferSize = AVAudioFrameCount(4096)
        engine.inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: hardwareFormat) { buffer, _ in
            session.process(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            session.close()
            throw error
        }
        return session
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let samples = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
        if let onLevel = levelHandler() { onLevel(VoiceSource.level(samples)) }
        let rms = EnergyGate<AVAudioPCMBuffer>.peakWindowRMS(samples, window: windowFrames)
        let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
        // The tap may reuse its buffer, so the gate keeps plain copies, never the tap's own memory. Only
        // forwarded chunks are resampled: in a silent room that is none, and resampling every buffer cost
        // more than the gate itself.
        guard let copy = Self.copy(buffer) else { return }
        let output = gate.push(copy, rms: rms, seconds: seconds)
        for chunk in output.forward {
            if let converted = convert(chunk) { input.yield(AnalyzerInput(buffer: converted)) }
        }
        if output.closed {
            // End of a spoken segment: ask for final results now instead of waiting for more audio.
            let analyzer = self.analyzer
            Task { try? await analyzer.finalize(through: nil) }
        }
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        out.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let target = UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList)
        for (from, to) in zip(source, target) {
            guard let src = from.mData, let dst = to.mData else { return nil }
            memcpy(dst, src, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return out
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        nonisolated(unsafe) var supplied = false
        nonisolated(unsafe) let source = buffer
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return source
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }

    /// Releases the microphone at once (the orange dot goes off), then winds the analyzer down.
    func close() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        input.finish()
        results.cancel()
        let analyzer = self.analyzer
        Task { await analyzer.cancelAndFinishNow() }
    }
}
