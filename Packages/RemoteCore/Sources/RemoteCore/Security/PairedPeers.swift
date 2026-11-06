import Foundation

/// Something whose TLS fingerprint is pinned after pairing.
public protocol PinnedPeer: Codable, Equatable, Sendable {
    var name: String { get }
    var fingerprint: DeviceFingerprint { get }
}

/// An iPhone the Mac has paired with.
public struct PairedDevice: PinnedPeer {
    public let name: String
    public let fingerprint: DeviceFingerprint
    public let pairedAt: Date

    public init(name: String, fingerprint: DeviceFingerprint, pairedAt: Date) {
        self.name = name
        self.fingerprint = fingerprint
        self.pairedAt = pairedAt
    }
}

/// The Mac an iPhone has paired with, plus where it was last reached.
public struct PairedHost: PinnedPeer {
    public let name: String
    public let fingerprint: DeviceFingerprint
    public let pairedAt: Date
    public let lastKnownHost: String?
    public let lastKnownPort: UInt16?

    public init(name: String, fingerprint: DeviceFingerprint, pairedAt: Date, lastKnownHost: String?, lastKnownPort: UInt16?) {
        self.name = name
        self.fingerprint = fingerprint
        self.pairedAt = pairedAt
        self.lastKnownHost = lastKnownHost
        self.lastKnownPort = lastKnownPort
    }

    /// Copy with an updated address (the fingerprint, i.e. the identity, never changes).
    public func reached(at host: String, port: UInt16) -> PairedHost {
        PairedHost(name: name, fingerprint: fingerprint, pairedAt: pairedAt, lastKnownHost: host, lastKnownPort: port)
    }
}
