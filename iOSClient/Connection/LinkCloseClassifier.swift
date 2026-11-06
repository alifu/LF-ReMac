import Foundation
import Network

/// Why a stream link ended, as observed by the link.
enum LinkCloseCause: Equatable, Sendable {
    /// We closed it (user disconnect).
    case local
    /// Network.framework parked the connection: refused, unreachable, or TLS refused in the handshake.
    case unreachable(String)
    /// The connection failed (TLS alert, reset...). `isTLS` when the error came from the TLS layer.
    case failed(String, isTLS: Bool)
    /// The Mac closed the stream cleanly.
    case closedByHost
    /// The Mac sent bytes that do not decode.
    case protocolError
}

/// What the link knew when it closed.
struct LinkHistory: Equatable, Sendable {
    var reachedReady = false
    var receivedFrame = false
    /// Seconds between `.ready` and the close; nil if never ready.
    var secondsAfterReady: TimeInterval?
    /// Our verify block saw a server key other than the paired one.
    var sawWrongHostKey = false
}

/// Turns a close into the message the connection screen shows (nil = no error to show).
///
/// TLS 1.3 caveat: the client reaches `.ready` before the server has judged our certificate, so a
/// Mac that no longer pairs us shows up as "closed (or TLS alert) right after ready, before any frame".
enum LinkCloseClassifier {
    static let rejectionWindow: TimeInterval = 5
    static let notRecognised = "This Mac does not recognise this iPhone. Pair again."
    static let wrongHostKey = "This Mac's security key does not match the paired Mac. Pair again."

    static func message(for cause: LinkCloseCause, history: LinkHistory) -> String? {
        if history.sawWrongHostKey { return wrongHostKey }
        if cause == .local { return nil }
        if isLikelyRejection(cause, history) { return notRecognised }
        switch cause {
        case .local: return nil
        case .unreachable(let detail): return "Cannot reach the Mac: \(detail)"
        case .failed(let detail, _): return detail
        case .closedByHost: return "The Mac closed the connection."
        case .protocolError: return "The Mac sent data this app does not understand."
        }
    }

    private static func isLikelyRejection(_ cause: LinkCloseCause, _ history: LinkHistory) -> Bool {
        guard history.reachedReady, !history.receivedFrame else { return false }
        if case .failed(_, isTLS: true) = cause { return true }
        guard cause == .closedByHost || isFailure(cause) else { return false }
        return (history.secondsAfterReady ?? .infinity) <= rejectionWindow
    }

    private static func isFailure(_ cause: LinkCloseCause) -> Bool {
        if case .failed = cause { return true }
        return false
    }

    static func cause(for error: NWError, parked: Bool) -> LinkCloseCause {
        let isTLS: Bool
        if case .tls = error { isTLS = true } else { isTLS = false }
        return parked ? .unreachable(error.localizedDescription) : .failed(error.localizedDescription, isTLS: isTLS)
    }
}
