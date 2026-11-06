import Foundation
import Testing
@testable import MacHost

struct PairingCountdownTests {
    private static let now = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test func formatsMinutesAndPaddedSeconds() {
        let expiresAt = Self.now.addingTimeInterval(125)

        #expect(PairingCountdown.text(until: expiresAt, now: Self.now) == "2:05")
    }

    @Test func showsZeroAtOrAfterExpiry() {
        #expect(PairingCountdown.text(until: Self.now, now: Self.now) == "0:00")
        #expect(PairingCountdown.text(until: Self.now, now: Self.now.addingTimeInterval(30)) == "0:00")
    }

    @Test func roundsPartialSecondsUp() {
        let expiresAt = Self.now.addingTimeInterval(59.2)

        #expect(PairingCountdown.text(until: expiresAt, now: Self.now) == "1:00")
    }

    @Test func showsFullTwoMinutesAtStart() {
        let expiresAt = Self.now.addingTimeInterval(120)

        #expect(PairingCountdown.text(until: expiresAt, now: Self.now) == "2:00")
    }
}
