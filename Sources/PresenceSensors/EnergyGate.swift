import Foundation

/// Decides which audio chunks are worth sending to speech recognition.
///
/// Speech recognition costs far more than an RMS sum, so it only sees audio while the level is above
/// the room's noise floor, plus a short pre-roll so the first syllable of the Trigger word is not cut,
/// and a short hangover so pauses between words do not split a Command.
struct EnergyGate<Chunk> {
    struct Output {
        /// Chunks to forward now, oldest first.
        var forward: [Chunk] = []
        /// The gate just closed: the speech segment is over.
        var closed = false
    }

    var minThreshold: Float = 0.01
    /// Speech must be this many times louder than the tracked noise floor.
    var floorFactor: Float = 3
    var preRollSeconds: Double = 0.3
    var hangoverSeconds: Double = 0.6

    private(set) var isOpen = false
    private(set) var noiseFloor: Float = 0.003
    private var preRoll: [(chunk: Chunk, seconds: Double)] = []
    private var quietSeconds: Double = 0

    var threshold: Float { max(minThreshold, noiseFloor * floorFactor) }

    mutating func push(_ chunk: Chunk, rms: Float, seconds: Double) -> Output {
        var output = Output()
        let loud = rms >= threshold
        if isOpen {
            // The floor creeps up very slowly while open, so steady fan noise loud enough to open the gate
            // closes it within a few seconds, while a few seconds of real speech barely moves it.
            noiseFloor += (rms - noiseFloor) * 0.002
            output.forward = [chunk]
            quietSeconds = loud ? 0 : quietSeconds + seconds
            if quietSeconds >= hangoverSeconds {
                isOpen = false
                output.closed = true
                quietSeconds = 0
            }
            return output
        }
        if loud {
            isOpen = true
            quietSeconds = 0
            output.forward = preRoll.map(\.chunk) + [chunk]
            preRoll.removeAll()
            return output
        }
        // Quiet audio moves the floor quickly; loud audio only through the slow rate above.
        noiseFloor += (rms - noiseFloor) * 0.05
        preRoll.append((chunk, seconds))
        var total = preRoll.reduce(0) { $0 + $1.seconds }
        while total > preRollSeconds + 1e-9, !preRoll.isEmpty {
            total -= preRoll.removeFirst().seconds
        }
        return output
    }

    /// The loudest RMS over windows of `window` samples, so a short loud word inside a long buffer still counts.
    static func peakWindowRMS(_ samples: UnsafeBufferPointer<Float>, window: Int) -> Float {
        guard !samples.isEmpty, window > 0 else { return 0 }
        var peak: Float = 0
        var start = 0
        while start < samples.count {
            let end = min(start + window, samples.count)
            var sum: Float = 0
            for i in start..<end { sum += samples[i] * samples[i] }
            peak = max(peak, (sum / Float(end - start)).squareRoot())
            start = end
        }
        return peak
    }
}
