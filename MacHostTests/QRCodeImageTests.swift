import AppKit
import CoreImage
import Testing
@testable import MacHost

struct QRCodeImageTests {
    private static let sampleMessage = "lfremac://pair?v=1&h=mac.local&p=47800&f=abc&s=ABCDEFGHJKMNPQRS"

    private static func decode(_ image: NSImage) -> [String] {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        let detector = CIDetector(
            ofType: CIDetectorTypeQRCode, context: nil,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        )
        let features = detector?.features(in: CIImage(cgImage: cgImage)) ?? []
        return features.compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    }

    @Test func generatedImageDecodesBackToTheSameMessage() {
        let image = QRCodeImage.make(from: Self.sampleMessage)

        let decoded = image.map(Self.decode) ?? []

        #expect(decoded == [Self.sampleMessage])
    }

    @Test func imageIsScaledByPointsPerModule() throws {
        let small = try #require(QRCodeImage.make(from: Self.sampleMessage, pointsPerModule: 4))
        let large = try #require(QRCodeImage.make(from: Self.sampleMessage, pointsPerModule: 8))

        #expect(large.size.width == small.size.width * 2)
    }

    @Test func emptyMessageProducesNoImage() {
        #expect(QRCodeImage.make(from: "") == nil)
    }

    @Test func nonPositiveScaleProducesNoImage() {
        #expect(QRCodeImage.make(from: Self.sampleMessage, pointsPerModule: 0) == nil)
    }
}
