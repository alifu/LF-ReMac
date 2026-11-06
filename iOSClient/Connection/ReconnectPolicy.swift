import Foundation

/// Which reconnect try the client is on, for the on-screen banner.
struct ReconnectStatus: Equatable, Sendable {
    let attempt: Int
    let total: Int
}

/// When to redial a Mac after the stream dropped by itself (Wi-Fi hiccup, network change, Mac busy).
///
/// Waits grow 1, 2, 4, 8 s then 15 s, for 8 tries (about a minute and a half), then gives up so a
/// Mac that is really gone does not keep the radio busy. Nothing here re-pairs or relaxes pinning:
/// each try is a normal pinned connection. A value type; each step returns the next state.
struct ReconnectPolicy: Equatable, Sendable {
    static let delays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8)]
        + Array(repeating: .seconds(15), count: 4)

    private let attemptsMade: Int

    init() {
        self.init(attemptsMade: 0)
    }

    private init(attemptsMade: Int) {
        self.attemptsMade = attemptsMade
    }

    /// The wait before the next try and the policy to keep, or nil once the tries are used up.
    func next() -> (delay: Duration, status: ReconnectStatus, policy: ReconnectPolicy)? {
        guard attemptsMade < Self.delays.count else { return nil }
        let used = attemptsMade + 1
        return (Self.delays[attemptsMade], ReconnectStatus(attempt: used, total: Self.delays.count), ReconnectPolicy(attemptsMade: used))
    }

    /// Whether a closed link is worth redialling. Never after the user disconnected, after the Mac
    /// closed the stream on purpose (it may have stopped hosting or given the session to another
    /// iPhone), when the Mac no longer recognises this iPhone, or when a wrong key answered.
    ///
    /// - Parameter wasEstablished: the Mac had accepted this iPhone and streamed to it. A try that
    ///   never got that far (Mac still unreachable) is also worth repeating, but only while a
    ///   reconnect cycle is already running.
    static func isRecoverable(_ close: LinkCloseSummary, wasEstablished: Bool) -> Bool {
        guard let message = close.message, !close.sawWrongHostKey else { return false }
        guard message != LinkCloseClassifier.notRecognised, !close.closedByHost else { return false }
        return wasEstablished || close.canTryAnotherAddress
    }
}
