import Testing
@testable import MacHost

struct PowerManagerTests {
    private final class Counter: @unchecked Sendable {
        var acquired = 0
        var released = 0
    }

    private func manager(_ counter: Counter, succeeds: Bool = true) -> PowerManager {
        PowerManager { _ in
            guard succeeds else { return nil }
            counter.acquired += 1
            return { counter.released += 1 }
        }
    }

    @Test func holdsOneAssertionNoMatterHowOftenEnabled() {
        let counter = Counter()
        let power = manager(counter)

        power.setKeepAwake(true)
        power.setKeepAwake(true)

        #expect(counter.acquired == 1)
        #expect(power.isHoldingAssertion)
    }

    @Test func releasesWhenDisabledAndIgnoresRepeatedDisable() {
        let counter = Counter()
        let power = manager(counter)
        power.setKeepAwake(true)

        power.setKeepAwake(false)
        power.setKeepAwake(false)

        #expect(counter.released == 1)
        #expect(!power.isHoldingAssertion)
    }

    @Test func releasesOnDeinit() {
        let counter = Counter()
        var power: PowerManager? = manager(counter)
        power?.setKeepAwake(true)

        power = nil

        #expect(counter.released == 1)
    }

    @Test func reportsNotHeldWhenTheSystemRefuses() {
        let power = manager(Counter(), succeeds: false)

        #expect(power.setKeepAwake(true) == false)
    }

    @Test func realAssertionIsCreatedAndReleased() {
        let power = PowerManager()

        #expect(power.setKeepAwake(true))
        power.setKeepAwake(false)
        #expect(!power.isHoldingAssertion)
    }
}
