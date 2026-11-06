import Foundation
import Network

/// Set from the TLS verify queue, read on the runner queue.
final class MismatchFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }

    func set() {
        lock.withLock { value = true }
    }
}

/// Host/port of an `.hostPort` endpoint as plain values (for "last known address").
public struct RemoteAddress: Equatable, Sendable {
    public let host: String?
    public let port: UInt16?

    public init(_ endpoint: NWEndpoint?) {
        guard case .hostPort(let host, let port)? = endpoint else {
            self.host = nil
            self.port = nil
            return
        }
        self.host = Self.string(host)
        self.port = port.rawValue
    }

    private static func string(_ host: NWEndpoint.Host) -> String? {
        switch host {
        case .name(let name, _): name
        case .ipv4(let address): "\(address)"
        case .ipv6(let address): "\(address)"
        @unknown default: nil
        }
    }
}

extension Duration {
    /// Seconds as `TimeInterval` (for Dispatch deadlines).
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
