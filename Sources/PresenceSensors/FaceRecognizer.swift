import CoreGraphics
import CoreImage
import CoreML
import CoreVideo
import Foundation
import Synchronization
import Vision

/// The Owner's face as a few unit-length SFace embeddings. Only these numbers are kept, never a picture.
public struct FaceSignature: Codable, Sendable, Equatable {
    public var vectors: [[Float]]
    public var threshold: Float

    public init(vectors: [[Float]], threshold: Float = FaceRecognizer.defaultThreshold) {
        self.vectors = vectors
        self.threshold = threshold
    }
}

/// Turns a detected face into an SFace embedding and compares embeddings with a Face signature.
public final class FaceRecognizer: Sendable {
    /// SFace's published cosine threshold for "same person" is 0.363; this sits higher because a
    /// false accept (someone else waking the screens) is what the Owner asked to prevent.
    public static let defaultThreshold: Float = 0.55
    static let minimumSamples = 10
    static let maximumCentroids = 3
    static let embeddingLength = 128
    /// The model is about 18 MB in memory; it is dropped once recognition has been idle this long.
    static let releaseAfterSeconds: Double = 60

    /// Core ML documents MLModel predictions as safe from any thread; the type just is not marked Sendable.
    private struct SharedModel: @unchecked Sendable {
        let model: MLModel
    }

    private struct State {
        var model: SharedModel?
        var lastUse: Double = 0
        var releaseScheduled = false
    }

    private let state = Mutex(State())
    private let context = CIContext(options: [.cacheIntermediates: false])

    public init() {}

    // MARK: - Embedding

    public func embedding(of pixels: CVPixelBuffer, face: VNFaceObservation) -> [Float]? {
        let size = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
        guard let points = Self.alignmentPoints(face, imageSize: size),
              let transform = Self.similarity(from: points, to: Self.referencePoints),
              let crop = aligned(pixels, transform),
              let model = loadedModel()
        else { return nil }
        guard let input = try? MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: crop)]),
              let output = try? model.prediction(from: input),
              let array = output.featureValue(for: "embedding")?.multiArrayValue,
              array.count == Self.embeddingLength
        else { return nil }
        return Self.normalised((0..<array.count).map { array[$0].floatValue })
    }

    /// Where SFace expects the eyes, nose tip and mouth corners in its 112x112 input, origin bottom-left
    /// to match Core Image. From OpenCV's FaceRecognizerSF, flipped vertically.
    static let referencePoints: [CGPoint] = [
        CGPoint(x: 38.2946, y: 112 - 51.6963), CGPoint(x: 73.5318, y: 112 - 51.5014),
        CGPoint(x: 56.0252, y: 112 - 71.7366),
        CGPoint(x: 41.5493, y: 112 - 92.3655), CGPoint(x: 70.7299, y: 112 - 92.2041),
    ]

    /// Eye centres, nose tip and mouth corners in image pixels, origin bottom-left, each pair ordered left
    /// to right in the image the way the reference points are.
    static func alignmentPoints(_ face: VNFaceObservation, imageSize: CGSize) -> [CGPoint]? {
        guard let marks = face.landmarks,
              let leftEye = marks.leftEye?.pointsInImage(imageSize: imageSize), !leftEye.isEmpty,
              let rightEye = marks.rightEye?.pointsInImage(imageSize: imageSize), !rightEye.isEmpty,
              let crest = marks.noseCrest?.pointsInImage(imageSize: imageSize), !crest.isEmpty,
              let lips = marks.outerLips?.pointsInImage(imageSize: imageSize), lips.count >= 2
        else { return nil }
        let eyes = [centroid(leftEye), centroid(rightEye)].sorted { $0.x < $1.x }
        // The bottom of the nose crest is the tip on an upright face.
        let nose = crest.min { $0.y < $1.y }!
        let mouth = [lips.min { $0.x < $1.x }!, lips.max { $0.x < $1.x }!]
        return eyes + [nose] + mouth
    }

    /// The least-squares rotation, uniform scale and translation taking `src` onto `dst` (Umeyama, no
    /// reflection), which is how SFace's training crops were aligned.
    static func similarity(from src: [CGPoint], to dst: [CGPoint]) -> CGAffineTransform? {
        guard src.count == dst.count, src.count >= 2 else { return nil }
        let sc = centroid(src), dc = centroid(dst)
        var a = 0.0, b = 0.0, variance = 0.0
        for (s, d) in zip(src, dst) {
            let sx = s.x - sc.x, sy = s.y - sc.y, dx = d.x - dc.x, dy = d.y - dc.y
            a += sx * dx + sy * dy
            b += sx * dy - sy * dx
            variance += sx * sx + sy * sy
        }
        guard variance > 1e-9 else { return nil }
        // For 2D the optimal similarity is z -> (a + ib) / |s|^2 * z in complex form.
        let ca = a / variance, cb = b / variance
        let tx = dc.x - (ca * sc.x - cb * sc.y)
        let ty = dc.y - (cb * sc.x + ca * sc.y)
        return CGAffineTransform(a: ca, b: cb, c: -cb, d: ca, tx: tx, ty: ty)
    }

    private func aligned(_ pixels: CVPixelBuffer, _ transform: CGAffineTransform) -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        guard CVPixelBufferCreate(nil, 112, 112, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &out) == kCVReturnSuccess,
              let out
        else { return nil }
        let image = CIImage(cvPixelBuffer: pixels).transformed(by: transform)
            .cropped(to: CGRect(x: 0, y: 0, width: 112, height: 112))
        context.render(image, to: out, bounds: CGRect(x: 0, y: 0, width: 112, height: 112), colorSpace: CGColorSpaceCreateDeviceRGB())
        return out
    }

    // MARK: - Model lifetime

    private func loadedModel() -> MLModel? {
        let now = ProcessInfo.processInfo.systemUptime
        let (cached, schedule) = state.withLock { s -> (SharedModel?, Bool) in
            s.lastUse = now
            let schedule = !s.releaseScheduled
            s.releaseScheduled = true
            return (s.model, schedule)
        }
        if schedule { scheduleRelease(after: Self.releaseAfterSeconds) }
        if let cached { return cached.model }
        guard let model = Self.loadModel() else { return nil }
        let shared = SharedModel(model: model)
        return state.withLock { s in
            if s.model == nil { s.model = shared }
            return s.model
        }?.model
    }

    private func scheduleRelease(after seconds: Double) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let wait = self.state.withLock { s -> Double? in
                let idle = now - s.lastUse
                if idle >= Self.releaseAfterSeconds {
                    s.model = nil
                    s.releaseScheduled = false
                    return nil
                }
                return Self.releaseAfterSeconds - idle
            }
            if let wait { self.scheduleRelease(after: wait) }
        }
    }

    static func loadModel() -> MLModel? {
        guard let url = Bundle.module.url(forResource: "SFace", withExtension: "mlmodelc") else { return nil }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        return try? MLModel(contentsOf: url, configuration: config)
    }

    // MARK: - Signature maths

    /// The mean of the enrolment embeddings plus up to three cluster centres, so a few distinct poses or
    /// lighting conditions each get their own vector. Nil with fewer than ten samples.
    public static func signature(from embeddings: [[Float]]) -> FaceSignature? {
        let samples = embeddings.filter { $0.count == embeddingLength }.map(normalised)
        guard samples.count >= minimumSamples else { return nil }
        let mean = normalised(average(samples))
        // A cluster this small is a stray frame (someone else, a half-visible face), not a pose of the
        // Owner; kept, it would match that stray on its own and bypass the threshold.
        let minimumCluster = max(3, samples.count / 5)
        let centroids = kMeans(samples, k: maximumCentroids, minimumCluster: minimumCluster)
        return FaceSignature(vectors: [mean] + centroids)
    }

    public static func matches(_ embedding: [Float], _ signature: FaceSignature) -> Bool {
        guard let best = signature.vectors.map({ cosine(embedding, $0) }).max() else { return false }
        return best >= signature.threshold
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return -1 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    static func normalised(_ v: [Float]) -> [Float] {
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? v.map { $0 / norm } : v
    }

    /// Deterministic k-means on unit vectors: farthest-point seeding, a fixed number of rounds, and
    /// clusters under `minimumCluster` samples dropped, so the same enrolment always gives the same signature.
    static func kMeans(_ samples: [[Float]], k: Int, minimumCluster: Int = 1, rounds: Int = 10) -> [[Float]] {
        guard let first = samples.first, k > 0 else { return [] }
        var centres = [first]
        while centres.count < min(k, samples.count) {
            let next = samples.max { a, b in
                centres.map { cosine(a, $0) }.max()! > centres.map { cosine(b, $0) }.max()!
            }!
            if centres.contains(next) { break }
            centres.append(next)
        }
        var groups: [[[Float]]] = []
        for _ in 0..<rounds {
            groups = Array(repeating: [], count: centres.count)
            for s in samples {
                let nearest = centres.indices.max { cosine(s, centres[$0]) < cosine(s, centres[$1]) }!
                groups[nearest].append(s)
            }
            centres = groups.filter { !$0.isEmpty }.map { normalised(average($0)) }
        }
        return groups.filter { $0.count >= max(minimumCluster, 1) }.map { normalised(average($0)) }
    }

    private static func average(_ vectors: [[Float]]) -> [Float] {
        var sum = [Float](repeating: 0, count: vectors[0].count)
        for v in vectors { for i in sum.indices { sum[i] += v[i] } }
        return sum.map { $0 / Float(vectors.count) }
    }

    private static func centroid(_ points: [CGPoint]) -> CGPoint {
        let n = CGFloat(points.count)
        return CGPoint(x: points.map(\.x).reduce(0, +) / n, y: points.map(\.y).reduce(0, +) / n)
    }
}
