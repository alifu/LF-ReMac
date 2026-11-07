import Testing
@testable import MacHost

struct DisplayWakerTests {
    private final class Counter: @unchecked Sendable {
        var woke = 0
        var held = 0
        var released = 0
    }

    private func waker(_ counter: Counter) -> DisplayWaker {
        DisplayWaker(
            wake: { _ in counter.woke += 1; return true },
            hold: { _ in
                counter.held += 1
                return { counter.released += 1 }
            }
        )
    }

    @Test func wakesTheDisplayAndHoldsOneAssertion() {
        let counter = Counter()
        let waker = waker(counter)

        waker.wakeAndHold()
        waker.wakeAndHold()

        #expect(counter.woke == 2)
        #expect(counter.held == 1)
        #expect(waker.isHoldingDisplayOn)
    }

    @Test func releasesTheHoldOnce() {
        let counter = Counter()
        let waker = waker(counter)
        waker.wakeAndHold()

        waker.releaseHold()
        waker.releaseHold()

        #expect(counter.released == 1)
        #expect(!waker.isHoldingDisplayOn)
    }

    @Test func realWakeAndHoldCanBeReleased() {
        let waker = DisplayWaker()

        waker.wakeAndHold()
        #expect(waker.isHoldingDisplayOn)
        waker.releaseHold()
        #expect(!waker.isHoldingDisplayOn)
    }
}
