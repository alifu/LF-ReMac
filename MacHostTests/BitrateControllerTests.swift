import Foundation
import Testing
@testable import MacHost

struct BitrateControllerTests {
    private static let max = 6_000_000
    private static let start = Date(timeIntervalSinceReferenceDate: 1_000)

    private static func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }
    private static func make() -> BitrateController { BitrateController(maxBitRate: max) }

    @Test func startsAtMax() {
        #expect(Self.make().targetBitRate == Self.max)
    }

    @Test func congestionCutsBySeventyPercent() {
        var controller = Self.make()
        controller.handle(.congested(at: Self.at(0)))
        #expect(controller.targetBitRate == 4_200_000)
    }

    @Test func neverCutsBelowFloor() {
        var controller = Self.make()
        for index in 0..<10 { controller.handle(.congested(at: Self.at(Double(index) * 2))) }
        #expect(controller.targetBitRate == BitrateController.floorBitRate)
    }

    @Test func congestionWithinOneSecondOfACutIsIgnored() {
        var controller = Self.make()
        controller.handle(.congested(at: Self.at(0)))
        controller.handle(.congested(at: Self.at(0.9)))
        #expect(controller.targetBitRate == 4_200_000)
        controller.handle(.congested(at: Self.at(1.0)))
        #expect(controller.targetBitRate == 2_940_000)
    }

    @Test func noRaiseDuringQuietWindow() {
        var controller = Self.make()
        controller.handle(.congested(at: Self.at(0)))
        controller.handle(.tick(at: Self.at(4.9)))
        #expect(controller.targetBitRate == 4_200_000)
    }

    @Test func ignoredCongestionStillExtendsQuietWindow() {
        var controller = Self.make()
        controller.handle(.congested(at: Self.at(0)))
        controller.handle(.congested(at: Self.at(0.8)))
        controller.handle(.tick(at: Self.at(5.0)))
        #expect(controller.targetBitRate == 4_200_000)
        controller.handle(.tick(at: Self.at(5.8)))
        #expect(controller.targetBitRate == 4_800_000)
    }

    @Test func recoversInStepsOfTenPercentOfMaxAtMostEveryTwoSeconds() {
        var controller = Self.make()
        controller.handle(.congested(at: Self.at(0)))
        controller.handle(.tick(at: Self.at(5)))
        #expect(controller.targetBitRate == 4_800_000)
        controller.handle(.tick(at: Self.at(6)))
        #expect(controller.targetBitRate == 4_800_000)
        controller.handle(.tick(at: Self.at(7)))
        #expect(controller.targetBitRate == 5_400_000)
    }

    @Test func raiseIsCappedAtMax() {
        var controller = Self.make()
        controller.handle(.congested(at: Self.at(0)))
        for index in 0..<20 { controller.handle(.tick(at: Self.at(5 + Double(index) * 2))) }
        #expect(controller.targetBitRate == Self.max)
    }

    @Test func tickAtMaxDoesNothing() {
        var controller = Self.make()
        controller.handle(.tick(at: Self.at(100)))
        #expect(controller.targetBitRate == Self.max)
    }

    @Test func resetReturnsToMax() {
        var controller = Self.make()
        controller.handle(.congested(at: Self.at(0)))
        controller.reset()
        #expect(controller.targetBitRate == Self.max)
        controller.handle(.congested(at: Self.at(0.1)))
        #expect(controller.targetBitRate == 4_200_000)
    }

    @Test func floorNeverExceedsMax() {
        var controller = BitrateController(maxBitRate: 1_000_000)
        controller.handle(.congested(at: Self.at(0)))
        #expect(controller.targetBitRate == 1_000_000)
    }
}
