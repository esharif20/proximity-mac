import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import Testing
@testable import PresenceSensors

/// A unit vector along one axis, mixed a little toward another, so angles between samples are known.
private func unit(_ axis: Int, tilt: Float = 0, toward other: Int = 127) -> [Float] {
    var v = [Float](repeating: 0, count: 128)
    v[axis] = 1
    v[other] += tilt
    return FaceRecognizer.normalised(v)
}

@Suite struct FaceRecognizerTests {
    @Test func cosineOfKnownVectors() {
        #expect(FaceRecognizer.cosine([1, 0], [1, 0]) == 1)
        #expect(FaceRecognizer.cosine([1, 0], [0, 1]) == 0)
        #expect(abs(FaceRecognizer.cosine([1, 0], [1, 1]) - 0.70710677) < 1e-6)
        #expect(FaceRecognizer.cosine([1, 0], [1, 0, 0]) == -1)
    }

    @Test func matchesUsesTheBestVectorAgainstTheThreshold() {
        let signature = FaceSignature(vectors: [unit(0), unit(1)], threshold: 0.55)
        // cos(45 deg) = 0.707 passes, cos(60 deg) = 0.5 does not.
        #expect(FaceRecognizer.matches(FaceRecognizer.normalised([0, 1, 1] + .init(repeating: 0, count: 125)), signature))
        let sixty = [Float](arrayLiteral: 0.5, 0.8660254) + .init(repeating: 0, count: 126)
        #expect(FaceRecognizer.matches(sixty, signature))
        #expect(!FaceRecognizer.matches(unit(2), signature))
        #expect(!FaceRecognizer.matches(unit(2), FaceSignature(vectors: [], threshold: 0.55)))
        #expect(FaceSignature(vectors: []).threshold == 0.55)
    }

    @Test func signatureNeedsTenSamples() {
        let nine = (0..<9).map { unit(0, tilt: Float($0) * 0.01) }
        #expect(FaceRecognizer.signature(from: nine) == nil)
        #expect(FaceRecognizer.signature(from: nine + [[1, 2, 3]]) == nil, "wrong-length vectors do not count")
        #expect(FaceRecognizer.signature(from: nine + [unit(0)]) != nil)
    }

    @Test func signatureKeepsTheMeanAndUpToThreeCentroids() throws {
        // Three tight poses far apart from each other.
        let samples = (0..<12).map { unit($0 % 3, tilt: Float($0 / 3) * 0.02) }
        let signature = try #require(FaceRecognizer.signature(from: samples))
        #expect(signature.vectors.count == 4)
        #expect(signature.threshold == 0.55)
        for v in signature.vectors { #expect(abs(v.reduce(0) { $0 + $1 * $1 } - 1) < 1e-4) }
        // The mean sits between the poses; each centroid sits on one pose.
        let mean = signature.vectors[0]
        #expect(abs(mean[0] - mean[1]) < 0.05 && abs(mean[1] - mean[2]) < 0.05)
        let axes = signature.vectors.dropFirst().map { c in c.indices.max { c[$0] < c[$1] }! }
        #expect(Set(axes) == [0, 1, 2])
        for s in samples { #expect(FaceRecognizer.matches(s, signature)) }
        #expect(FaceRecognizer.signature(from: samples) == signature, "same enrolment, same signature")
    }

    @Test func oneTightPoseStillGivesASignature() throws {
        let samples = (0..<10).map { _ in unit(5) }
        let signature = try #require(FaceRecognizer.signature(from: samples))
        #expect(signature.vectors.count == 2, "identical samples collapse to one centroid")
    }

    @Test func similarityRecoversAKnownTransform() throws {
        let truth = CGAffineTransform(translationX: 12, y: -7).rotated(by: 0.3).scaledBy(x: 0.4, y: 0.4)
        let src = [CGPoint(x: 100, y: 200), CGPoint(x: 180, y: 205), CGPoint(x: 140, y: 160),
                   CGPoint(x: 110, y: 120), CGPoint(x: 170, y: 122)]
        let dst = src.map { $0.applying(truth) }
        let found = try #require(FaceRecognizer.similarity(from: src, to: dst))
        for (s, d) in zip(src, dst) {
            let p = s.applying(found)
            #expect(abs(p.x - d.x) < 1e-6 && abs(p.y - d.y) < 1e-6)
        }
        #expect(FaceRecognizer.similarity(from: [.zero, .zero], to: [.zero, .zero]) == nil)
    }

    @Test func referencePointsAreUprightInCoreImageSpace() {
        let r = FaceRecognizer.referencePoints
        #expect(r[0].x < r[1].x && r[3].x < r[4].x, "pairs run left to right")
        #expect(r[0].y > r[2].y && r[2].y > r[3].y, "eyes above nose above mouth, origin bottom-left")
    }

    @Test func bundledModelOutputs128Floats() throws {
        let model = try #require(FaceRecognizer.loadModel())
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 112, 112, kCVPixelFormatType_32BGRA, nil, &buffer)
        let pixels = try #require(buffer)
        let input = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: pixels)])
        let output = try model.prediction(from: input)
        let array = try #require(output.featureValue(for: "embedding")?.multiArrayValue)
        #expect(array.count == 128)
        #expect((0..<128).allSatisfy { array[$0].floatValue.isFinite })
    }
}

@Suite struct FaceRecognizerSignatureStoreTests {
    @Test func roundTripAndDelete() throws {
        let store = FaceSignatureStore(service: "io.github.esharif20.proximity-mac.face.tests.\(UUID().uuidString)")
        defer { store.delete() }
        #expect(store.load() == nil)
        let signature = FaceSignature(vectors: [unit(0), unit(1)], threshold: 0.6)
        do {
            try store.save(signature)
        } catch let error as FaceSignatureStore.StoreError {
            // An unsigned test runner or a locked CI keychain cannot store items; that is not a code fault.
            withKnownIssue("Keychain unavailable: \(error.status)") { throw error }
            return
        }
        #expect(store.load() == signature)
        var changed = signature
        changed.threshold = 0.7
        try store.save(changed)
        #expect(store.load() == changed, "saving again replaces the one item")
        store.delete()
        #expect(store.load() == nil)
    }
}
