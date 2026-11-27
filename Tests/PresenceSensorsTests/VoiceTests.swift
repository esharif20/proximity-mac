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

    @Test func playbackOnlyAppsDoNotCount() {
        let processes = [MicUsage.ProcessInput(pid: 77, runningInput: false)]
        #expect(!MicUsage.otherAppCapturing(processes: processes, ownPID: 42))
    }

    @Test func liveReadDoesNotCrash() {
        _ = MicUsage().micInUseByOtherApp()
    }

    @Test func voiceSourceStopsCleanlyWithoutStarting() {
        let source = VoiceSource()
        source.onTranscript { _ in }
        source.stop()
    }
}
