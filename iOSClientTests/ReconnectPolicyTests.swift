import Testing
@testable import iOSClient

struct ReconnectPolicyTests {
    private func close(
        message: String? = "The connection was reset.", canTryAnother: Bool = false,
        wrongKey: Bool = false, closedByHost: Bool = false
    ) -> LinkCloseSummary {
        LinkCloseSummary(message: message, canTryAnotherAddress: canTryAnother, sawWrongHostKey: wrongKey, closedByHost: closedByHost)
    }

    @Test func waitsGrowThenStayAtFifteenSeconds() {
        var policy = ReconnectPolicy()
        var delays: [Duration] = []

        while let next = policy.next() {
            delays.append(next.delay)
            policy = next.policy
        }

        #expect(delays == [.seconds(1), .seconds(2), .seconds(4), .seconds(8)] + Array(repeating: .seconds(15), count: 4))
    }

    @Test func statusCountsFromOneAndEndsAtTheTotal() throws {
        let first = try #require(ReconnectPolicy().next())
        #expect(first.status == ReconnectStatus(attempt: 1, total: 8))

        var policy = first.policy
        var last = first.status
        while let next = policy.next() {
            last = next.status
            policy = next.policy
        }
        #expect(last == ReconnectStatus(attempt: 8, total: 8))
    }

    @Test func aDroppedStreamIsRecoverable() {
        #expect(ReconnectPolicy.isRecoverable(close(), wasEstablished: true))
    }

    @Test func userDisconnectIsNeverRecoverable() {
        #expect(!ReconnectPolicy.isRecoverable(close(message: nil), wasEstablished: true))
    }

    @Test func aCleanCloseByTheMacIsNotRecoverable() {
        #expect(!ReconnectPolicy.isRecoverable(close(closedByHost: true), wasEstablished: true))
    }

    @Test func notBeingRecognisedIsNotRecoverable() {
        let summary = close(message: LinkCloseClassifier.notRecognised, canTryAnother: true)
        #expect(!ReconnectPolicy.isRecoverable(summary, wasEstablished: true))
    }

    @Test func aWrongKeyIsNotRecoverable() {
        #expect(!ReconnectPolicy.isRecoverable(close(wrongKey: true), wasEstablished: true))
    }

    @Test func aFailedTryDuringAReconnectCycleIsRecoverable() {
        #expect(ReconnectPolicy.isRecoverable(close(canTryAnother: true), wasEstablished: false))
    }

    @Test func aLinkThatNeverStreamedIsNotRecoverableOutsideACycle() {
        #expect(!ReconnectPolicy.isRecoverable(close(canTryAnother: false), wasEstablished: false))
    }
}
