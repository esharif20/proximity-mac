import Foundation

/// Distance from the screen, estimated from how wide a face looks in the camera image.
public enum Distance {
    /// An average adult face is about 15 cm wide; used until the person calibrates.
    static let typicalFaceWidthCm = 15.0
    /// Typical built-in MacBook camera field of view.
    static let horizontalFieldOfViewDegrees = 70.0
    /// Calibration samples further apart than this share of the median mean the person moved.
    static let maxCalibrationSpread = 0.3
    static let minCalibrationSamples = 5

    /// Centimetres from the screen. A face of zero width is infinitely far.
    public static func estimate(faceWidthPx: Double, imageWidthPx: Double, calibration: Calibration?) -> Double {
        guard faceWidthPx > 0, imageWidthPx > 0 else { return .infinity }
        if let cal = calibration, cal.faceWidthPx > 0, cal.imageWidthPx > 0 {
            // Compare widths as a share of the frame so a different capture resolution gives the same answer.
            let faceShare = faceWidthPx / imageWidthPx
            let calShare = cal.faceWidthPx / cal.imageWidthPx
            return cal.distanceCm * calShare / faceShare
        }
        let halfAngle = horizontalFieldOfViewDegrees / 2 * .pi / 180
        let focalPx = imageWidthPx / 2 / tan(halfAngle)
        return typicalFaceWidthCm * focalPx / faceWidthPx
    }

    /// The median face width over the samples, or nil when there are too few or they disagree too much.
    public static func calibration(fromFaceWidths widths: [Double], imageWidthPx: Double, distanceCm: Double) -> Calibration? {
        guard widths.count >= minCalibrationSamples, imageWidthPx > 0, distanceCm > 0,
              widths.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        let sorted = widths.sorted()
        let mid = sorted.count / 2
        let median = sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
        guard (sorted[sorted.count - 1] - sorted[0]) / median <= maxCalibrationSpread else { return nil }
        return Calibration(faceWidthPx: median, imageWidthPx: imageWidthPx, distanceCm: distanceCm)
    }
}
