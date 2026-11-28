import Synchronization
import Testing
@testable import PresenceSensors

@Suite struct VoiceEnergyGateTests {
    typealias Gate = EnergyGate<Int>

    /// Pushes 30 ms chunks numbered from `start`; returns every forwarded chunk and how many times the gate closed.
    static func run(_ gate: inout Gate, levels: [Float], start: Int = 0) -> (forwarded: [Int], closes: Int) {
        var forwarded: [Int] = []
        var closes = 0
        for (i, level) in levels.enumerated() {
            let out = gate.push(start + i, rms: level, seconds: 0.03)
            forwarded += out.forward
            if out.closed { closes += 1 }
        }
        return (forwarded, closes)
    }

    @Test func silenceForwardsNothing() {
        var gate = Gate()
        let result = Self.run(&gate, levels: Array(repeating: 0.002, count: 2000))
        #expect(result.forwarded.isEmpty)
        #expect(!gate.isOpen)
    }

    @Test func speechOpensWithPreRollInOrder() {
        var gate = Gate()
        let quiet = Array(repeating: Float(0.002), count: 50)
        let result = Self.run(&gate, levels: quiet + [0.2])
        // 0.3 s of pre-roll at 30 ms a chunk is 10 chunks before the loud one.
        #expect(result.forwarded == Array(40...50))
        #expect(gate.isOpen)
    }

    @Test func shortPausesInsideACommandKeepTheGateOpen() {
        var gate = Gate()
        let speech: [Float] = Array(repeating: 0.2, count: 10) + Array(repeating: 0.002, count: 10)
            + Array(repeating: 0.2, count: 10)
        let result = Self.run(&gate, levels: speech)
        #expect(result.closes == 0)
        #expect(result.forwarded == Array(0..<30))
    }

    @Test func aTwoSecondCommandIsNotCutByItsOwnLoudness() {
        var gate = Gate()
        let result = Self.run(&gate, levels: Array(repeating: 0.002, count: 100) + Array(repeating: 0.1, count: 70))
        #expect(gate.isOpen)
        #expect(result.closes == 0)
    }

    @Test func closesOnceAfterTheHangover() {
        var gate = Gate()
        let result = Self.run(&gate, levels: Array(repeating: 0.2, count: 10) + Array(repeating: 0.002, count: 100))
        #expect(result.closes == 1)
        // 10 loud chunks plus 0.6 s (20 chunks) of hangover, then nothing.
        #expect(result.forwarded == Array(0..<30))
        #expect(!gate.isOpen)
    }

    @Test func aNoisyRoomRaisesTheThreshold() {
        var gate = Gate()
        let result = Self.run(&gate, levels: Array(repeating: 0.02, count: 1000))
        #expect(result.forwarded.count < 250, "steady fan noise must not keep recognition running")
        #expect(!gate.isOpen)
        #expect(gate.threshold > 0.02)
    }

    @Test func randomLevelsNeverDuplicateOrReorderChunks() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            var gate = Gate()
            let levels = (0..<300).map { _ in Bool.random(using: &rng) ? Float.random(in: 0...0.005, using: &rng) : Float.random(in: 0...0.5, using: &rng) }
            let result = Self.run(&gate, levels: levels)
            #expect(result.forwarded == result.forwarded.sorted())
            #expect(Set(result.forwarded).count == result.forwarded.count)
        }
    }

    @Test func peakWindowFindsAShortLoudBurst() {
        var samples = [Float](repeating: 0, count: 4800)
        // Unaligned with the 480-sample windows, but long enough to fill one of them.
        for i in 2000..<2960 { samples[i] = 0.5 }
        let rms = samples.withUnsafeBufferPointer { Gate.peakWindowRMS($0, window: 480) }
        #expect(abs(rms - 0.5) < 0.0001)
        #expect([Float]().withUnsafeBufferPointer { Gate.peakWindowRMS($0, window: 480) } == 0)
    }
}

@Suite struct VoiceMicUsageTests {
    @Test func ourOwnCaptureDoesNotCount() {
        let mine = MicUsage.ProcessInput(pid: 42, runningInput: true)
        #expect(!MicUsage.otherAppCapturing(processes: [mine], ownPID: 42))
    }

    @Test func anotherAppCapturingCounts() {
        let processes = [
            MicUsage.ProcessInput(pid: 42, runningInput: true),
            MicUsage.ProcessInput(pid: 77, runningInput: true),
        ]
        #expect(MicUsage.otherAppCapturing(processes: processes, ownPID: 42))
    }

    @Test func appleSpeechDaemonListeningForUsIsNotACall() {
        // Seen on this Mac: corespeechd starts capturing as soon as our SpeechAnalyzer listens.
        let processes = [
            MicUsage.ProcessInput(pid: 42, runningInput: true, name: "ProximityMac"),
            MicUsage.ProcessInput(pid: 1286, runningInput: true, name: "corespeechd"),
        ]
        #expect(!MicUsage.otherAppCapturing(processes: processes, ownPID: 42))
    }

    @Test func aCallAppAlongsideTheSpeechDaemonStillCounts() {
        let processes = [
            MicUsage.ProcessInput(pid: 1286, runningInput: true, name: "corespeechd"),
            MicUsage.ProcessInput(pid: 500, runningInput: true, name: "zoom.us"),
        ]
        #expect(MicUsage.otherAppCapturing(processes: processes, ownPID: 42))
    }

    @Test func playbackOnlyAppsDoNotCount() {
        let processes = [MicUsage.ProcessInput(pid: 77, runningInput: false)]
        #expect(!MicUsage.otherAppCapturing(processes: processes, ownPID: 42))
    }

    @Test func liveReadDoesNotCrash() {
        _ = MicUsage().micInUseByOtherApp()
    }

}

/// Counts what a fake opener was asked to do.
final class VoiceProbe: Sendable {
    struct Counts {
        var access = 0
        var opens = 0
        var closes = 0
        var isCurrent: (@Sendable () -> Bool)?
        var interrupt: (@Sendable () -> Void)?
        var text: (@Sendable (String) -> Void)?
    }
    let counts = Mutex(Counts())
    let allowed: Bool
    /// Seconds `open` takes, standing in for a model download.
    let openDelay: Double

    init(allowed: Bool = true, openDelay: Double = 0) {
        self.allowed = allowed
        self.openDelay = openDelay
    }

    var opener: VoiceSource.Opener {
        VoiceSource.Opener(
            requestAccess: { [self] in
                counts.withLock { $0.access += 1 }
                return allowed
            },
            open: { [self] isCurrent, onText, onInterrupted in
                counts.withLock {
                    $0.opens += 1
                    $0.isCurrent = isCurrent
                    $0.interrupt = onInterrupted
                    $0.text = onText
                }
                if openDelay > 0 { try? await Task.sleep(for: .seconds(openDelay)) }
                return { [self] in counts.withLock { $0.closes += 1 } }
            })
    }

    var access: Int { counts.withLock { $0.access } }
    var opens: Int { counts.withLock { $0.opens } }
    var closes: Int { counts.withLock { $0.closes } }
    var isCurrent: (@Sendable () -> Bool)? { counts.withLock { $0.isCurrent } }
    var interrupt: (@Sendable () -> Void)? { counts.withLock { $0.interrupt } }
    var text: (@Sendable (String) -> Void)? { counts.withLock { $0.text } }
}

func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@Suite struct VoiceSourceLifecycleTests {
    @Test func stopsCleanlyWithoutStarting() {
        let source = VoiceSource()
        source.onTranscript { _ in }
        source.stop()
    }

    @Test func deniedPermissionLetsALaterStartTryAgain() async {
        let probe = VoiceProbe(allowed: false)
        let source = VoiceSource(opener: probe.opener)
        source.start()
        #expect(await eventually { !source.isRunning })
        source.start()
        #expect(await eventually { probe.access == 2 })
        #expect(probe.opens == 0)
    }

    @Test func stopDuringSetupTellsSetupToGiveUp() async throws {
        let probe = VoiceProbe(openDelay: 0.3)
        let source = VoiceSource(opener: probe.opener)
        source.start()
        #expect(await eventually { probe.opens == 1 })
        let isCurrent = try #require(probe.isCurrent)
        #expect(isCurrent())
        source.stop()
        #expect(!isCurrent(), "setup must see the stop before it opens the input")
        // A session that finished opening anyway is closed straight away.
        #expect(await eventually { probe.closes == 1 })
        #expect(!source.isRunning)
    }

    @Test func aDeviceChangeReopensOnTheNewInput() async throws {
        let probe = VoiceProbe()
        let source = VoiceSource(opener: probe.opener)
        source.start()
        #expect(await eventually { probe.opens == 1 })
        try await Task.sleep(for: .milliseconds(50))
        let interrupt = try #require(probe.interrupt)
        interrupt()
        #expect(await eventually { probe.opens == 2 })
        #expect(probe.closes == 1)
        #expect(source.isRunning)
        // A late notification from the old engine must not restart again.
        interrupt()
        try await Task.sleep(for: .milliseconds(50))
        #expect(probe.opens == 2)
        source.stop()
        #expect(await eventually { probe.closes == 2 })
    }

    @Test func transcriptsReachTheHandler() async throws {
        let probe = VoiceProbe()
        let source = VoiceSource(opener: probe.opener)
        let heard = Mutex<[String]>([])
        source.onTranscript { text in heard.withLock { $0.append(text) } }
        source.start()
        #expect(await eventually { probe.text != nil })
        let deliver = try #require(probe.text)
        deliver("screen wake up")
        #expect(heard.withLock { $0 } == ["screen wake up"])
        source.stop()
    }

    @Test func releasingARunningSourceClosesTheMic() async throws {
        let probe = VoiceProbe()
        var source: VoiceSource? = VoiceSource(opener: probe.opener)
        source?.start()
        #expect(await eventually { probe.opens == 1 })
        try await Task.sleep(for: .milliseconds(50))
        source = nil
        #expect(await eventually { probe.closes == 1 })
    }
}
