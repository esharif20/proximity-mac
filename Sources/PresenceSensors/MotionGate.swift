import CoreVideo
import Foundation

/// A coarse luma picture of one frame: cheap enough to take on every delivered frame, fine enough to see
/// a hand move at desk distance.
struct LumaGrid: Equatable {
    static let columns = 40
    static let rows = 30
    /// 420v luma is video range: 16 is black and 235 is white.
    static let black = 16.0, white = 235.0

    var cells: [UInt8]

    init(cells: [UInt8]) {
        self.cells = cells
    }

    /// Averages a 2x2 patch at the centre of each cell, which halves the per-pixel sensor noise for four reads.
    /// nil for a buffer without a luma plane.
    init?(sampling pixels: CVPixelBuffer) {
        guard CVPixelBufferGetPlaneCount(pixels) >= 1,
              CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess
        else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let width = CVPixelBufferGetWidthOfPlane(pixels, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixels, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        guard width >= Self.columns * 2, height >= Self.rows * 2,
              let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0)?.assumingMemoryBound(to: UInt8.self)
        else { return nil }
        var cells = [UInt8](repeating: 0, count: Self.columns * Self.rows)
        for row in 0..<Self.rows {
            let y = min((2 * row + 1) * height / (2 * Self.rows), height - 2)
            for col in 0..<Self.columns {
                let x = min((2 * col + 1) * width / (2 * Self.columns), width - 2)
                let top = base + y * stride + x
                let sum = Int(top[0]) + Int(top[1]) + Int(top[stride]) + Int(top[stride + 1])
                cells[row * Self.columns + col] = UInt8(sum / 4)
            }
        }
        self.cells = cells
    }

    /// Mean frame brightness, 0 (black) to 1 (white).
    var brightness: Double {
        guard !cells.isEmpty else { return 0 }
        let mean = Double(cells.reduce(0) { $0 + Int($1) }) / Double(cells.count)
        return min(max((mean - Self.black) / (Self.white - Self.black), 0), 1)
    }
}

/// Says whether the scene changed since the previous frame, so Vision runs when something moves instead
/// of waiting for the next slow sample.
struct MotionGate {
    /// A cell must change by more than this many luma levels; dim-room sensor noise stays well under it.
    static let cellThreshold = 16
    /// This many changed cells (1% of the grid) is motion: a hand moving at the desk changes about 30.
    static let minChangedCells = 12

    private var previous: LumaGrid?

    /// Compares with the previous frame and keeps this one for the next comparison.
    mutating func update(_ grid: LumaGrid) -> Bool {
        defer { previous = grid }
        guard let previous, previous.cells.count == grid.cells.count,
              grid.cells.count == LumaGrid.columns * LumaGrid.rows
        else { return false }
        var changed = 0
        for i in grid.cells.indices where abs(Int(grid.cells[i]) - Int(previous.cells[i])) > Self.cellThreshold {
            changed += 1
            if changed >= Self.minChangedCells { return true }
        }
        return false
    }

    /// Forgets the previous frame, so a camera restart is not compared with a frame from long ago.
    mutating func reset() {
        previous = nil
    }
}
