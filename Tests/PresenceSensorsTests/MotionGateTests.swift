import CoreVideo
import Foundation
import Testing
@testable import PresenceSensors

@Suite struct MotionGateTests {
    static let cols = LumaGrid.columns, rows = LumaGrid.rows

    /// A mid-grey room with one brighter block, like a person against a wall.
    static func scene(blockAt x: Int, y: Int = 10, size: Int = 8, base: UInt8 = 90, block: UInt8 = 170) -> LumaGrid {
        var cells = [UInt8](repeating: base, count: Self.cols * Self.rows)
        for row in y..<min(y + size, rows) {
            for col in x..<min(x + size, cols) { cells[row * cols + col] = block }
        }
        return LumaGrid(cells: cells)
    }

    @Test func aStaticSceneIsNotMotion() {
        var gate = MotionGate()
        let frame = Self.scene(blockAt: 10)
        let first = gate.update(frame)
        #expect(!first, "the first frame has nothing to compare with")
        let later = (0..<20).map { _ in gate.update(frame) }
        #expect(!later.contains(true))
    }

    @Test func aShiftedBlockIsMotion() {
        var gate = MotionGate()
        _ = gate.update(Self.scene(blockAt: 10))
        let moved = gate.update(Self.scene(blockAt: 13))
        #expect(moved)
    }

    @Test func aSmallHandSizedShiftIsMotion() {
        // A hand at desk distance is about 4 cells across on a 40x30 grid.
        var gate = MotionGate()
        _ = gate.update(Self.scene(blockAt: 20, size: 4))
        let moved = gate.update(Self.scene(blockAt: 24, size: 4))
        #expect(moved)
    }

    @Test func sensorNoiseIsNotMotion() {
        // Dim-room sensor noise: every cell jitters by a few levels on every frame.
        var rng = SystemRandomNumberGenerator()
        var gate = MotionGate()
        let base = Self.scene(blockAt: 10)
        var flagged = 0
        for _ in 0..<200 {
            let noisy = base.cells.map { UInt8(clamping: Int($0) + Int.random(in: -6...6, using: &rng)) }
            if gate.update(LumaGrid(cells: noisy)) { flagged += 1 }
        }
        #expect(flagged == 0)
    }

    @Test func brightnessIsTheMeanOfTheGridFromVideoRange() {
        // 420v luma runs 16 (black) to 235 (white).
        #expect(LumaGrid(cells: [UInt8](repeating: 16, count: Self.cols * Self.rows)).brightness == 0)
        #expect(LumaGrid(cells: [UInt8](repeating: 235, count: Self.cols * Self.rows)).brightness == 1)
        let half = LumaGrid(cells: (0..<Self.cols * Self.rows).map { $0.isMultiple(of: 2) ? 16 : 235 })
        #expect(abs(half.brightness - 0.5) < 0.001)
        #expect(LumaGrid(cells: [UInt8](repeating: 0, count: Self.cols * Self.rows)).brightness == 0, "clamped below black")
    }

    @Test func gridIsSampledFromTheLumaPlane() throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 640, 480, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &buffer)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = try #require(CVPixelBufferGetBaseAddressOfPlane(pixels, 0)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        // Left half black, right half white.
        for y in 0..<480 { for x in 0..<640 { base[y * stride + x] = x < 320 ? 16 : 235 } }
        CVPixelBufferUnlockBaseAddress(pixels, [])

        let grid = try #require(LumaGrid(sampling: pixels))
        #expect(grid.cells.count == Self.cols * Self.rows)
        #expect(grid.cells[0] == 16)
        #expect(grid.cells[Self.cols - 1] == 235)
        #expect(abs(grid.brightness - 0.5) < 0.01)
    }

    @Test func aWrongSizedGridIsRejectedNotCompared() {
        var gate = MotionGate()
        _ = gate.update(Self.scene(blockAt: 10))
        let moved = gate.update(LumaGrid(cells: [1, 2, 3]))
        #expect(!moved)
    }

    @Test func motionAtTheSideIsNotCentral() {
        var gate = MotionGate()
        _ = gate.compare(Self.scene(blockAt: 0, size: 4))
        let side = gate.compare(Self.scene(blockAt: 2, y: 20, size: 4))
        #expect(side.any, "the gate still wakes Vision for it")
        #expect(!side.central)
        _ = gate.compare(Self.scene(blockAt: 10))
        let middle = gate.compare(Self.scene(blockAt: 13))
        #expect(middle == MotionGate.Change(any: true, central: true))
    }

    @Test func motionIsCarriedToTheNextObservationOnly() {
        var gate = MotionGate()
        var tally = MotionTally()
        let blank = Observation(source: .camera, person: false)
        tally.note(gate.compare(Self.scene(blockAt: 10)))
        tally.note(gate.compare(Self.scene(blockAt: 13)))
        // The grid after the movement is still, as on the frame the next pass runs on.
        tally.note(gate.compare(Self.scene(blockAt: 13)))
        #expect(tally.stamp(blank).motion == true, "movement between passes counts")
        tally.note(gate.compare(Self.scene(blockAt: 13)))
        #expect(tally.stamp(blank).motion == false, "used up by the previous Observation")
    }
}
