import Foundation
import Network

/// How one link attempt ended, as far as choosing the next candidate is concerned.
struct LinkCloseSummary: Equatable, Sendable {
    /// What to show if this is the last attempt (nil = nothing to show, e.g. the user disconnected).
    let message: String?
    /// The link never got a frame from an accepting Mac and was not closed by us.
    let canTryAnotherAddress: Bool
    /// Whoever answered presented a key other than the paired Mac's.
    let sawWrongHostKey: Bool
}

/// Walks a paired Mac's candidate addresses: a failed attempt (wrong key, unreachable, ...) moves
/// on to the next one, so a LAN device answering under the Mac's Bonjour name cannot block the
/// real Mac. A value type: each step returns the next state.
struct ConnectionAttempts: Equatable, Sendable {
    enum Step: Equatable, Sendable {
        case dial(NWEndpoint)
        /// No candidate left; show `message` (nil = nothing to show).
        case giveUp(message: String?)
    }

    private let remaining: [NWEndpoint]
    private let sawWrongHostKey: Bool

    init(candidates: [NWEndpoint]) {
        self.init(remaining: candidates, sawWrongHostKey: false)
    }

    private init(remaining: [NWEndpoint], sawWrongHostKey: Bool) {
        self.remaining = remaining
        self.sawWrongHostKey = sawWrongHostKey
    }

    /// The first address to dial, and the state to keep for the next failure.
    func start() -> (Step, ConnectionAttempts) {
        guard let first = remaining.first else { return (.giveUp(message: Self.noAddress), self) }
        return (.dial(first), ConnectionAttempts(remaining: Array(remaining.dropFirst()), sawWrongHostKey: sawWrongHostKey))
    }

    /// What to do after the current attempt closed.
    func next(after close: LinkCloseSummary) -> (Step, ConnectionAttempts) {
        let sawWrongKey = sawWrongHostKey || close.sawWrongHostKey
        let updated = ConnectionAttempts(remaining: remaining, sawWrongHostKey: sawWrongKey)
        if close.canTryAnotherAddress, !remaining.isEmpty {
            return updated.start()
        }
        return (.giveUp(message: Self.finalMessage(close, sawWrongKey: sawWrongKey)), updated)
    }

    static let noAddress = "This Mac was not found on this network."

    /// A wrong key on an earlier address means a device impersonated the Mac; say so instead of
    /// a later "cannot reach" (but keep "the Mac does not recognise this iPhone": it was reached).
    private static func finalMessage(_ close: LinkCloseSummary, sawWrongKey: Bool) -> String? {
        guard sawWrongKey, close.canTryAnotherAddress, close.message != LinkCloseClassifier.notRecognised else {
            return close.message
        }
        return LinkCloseClassifier.wrongHostKey
    }
}
