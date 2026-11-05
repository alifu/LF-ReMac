import Testing
@testable import MacHost

struct CaptureSizeTests {
    @Test func keepsSizeWhenAlreadyWithinLimit() {
        let size = CaptureSize.fitting(width: 1280, height: 720, maxLongSide: 1920)

        #expect(size == CaptureSize(width: 1280, height: 720))
    }

    @Test func scalesDownLandscapeKeepingAspectRatio() {
        let size = CaptureSize.fitting(width: 3840, height: 2160, maxLongSide: 1920)

        #expect(size == CaptureSize(width: 1920, height: 1080))
    }

    @Test func scalesDownPortraitUsingHeightAsLongSide() {
        let size = CaptureSize.fitting(width: 2160, height: 3840, maxLongSide: 1920)

        #expect(size == CaptureSize(width: 1080, height: 1920))
    }

    @Test func roundsDimensionsDownToEvenNumbersForVideoEncoders() {
        let size = CaptureSize.fitting(width: 2561, height: 1441, maxLongSide: 1921)

        #expect(size.width % 2 == 0)
        #expect(size.height % 2 == 0)
    }

    @Test func neverReturnsZeroForTinyInput() {
        let size = CaptureSize.fitting(width: 1, height: 1, maxLongSide: 1920)

        #expect(size.width >= 2)
        #expect(size.height >= 2)
    }
}
