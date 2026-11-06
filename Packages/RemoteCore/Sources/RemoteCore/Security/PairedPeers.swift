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

/// The Mac an iPhone has paired with, plus where it was last reached and where the user saved it.
///
/// `lastKnown*` is overwritten by every successful connection; `saved*` is set only by the user
/// (e.g. a Tailscale name) and is never touched by a connection. The saved fields are optional, so
/// JSON stored before they existed decodes with both nil.
public struct PairedHost: PinnedPeer {
    public let name: String
    public let fingerprint: DeviceFingerprint
    public let pairedAt: Date
    public let lastKnownHost: String?
    public let lastKnownPort: UInt16?
    public let savedHost: String?
    public let savedPort: UInt16?
    /// Hardware addresses the Mac reported for Wake-on-LAN (optional so older JSON still decodes).
    public let wakeMACs: [String]?

    /// The stored addresses that are valid, as typed values.
    public var wakeAddresses: [MACAddress] { (wakeMACs ?? []).compactMap(MACAddress.init) }

    public init(
        name: String,
        fingerprint: DeviceFingerprint,
        pairedAt: Date,
        lastKnownHost: String?,
        lastKnownPort: UInt16?,
        savedHost: String? = nil,
        savedPort: UInt16? = nil,
        wakeMACs: [String]? = nil
    ) {
        self.name = name
        self.fingerprint = fingerprint
        self.pairedAt = pairedAt
        self.lastKnownHost = lastKnownHost
        self.lastKnownPort = lastKnownPort
        self.savedHost = savedHost
        self.savedPort = savedPort
        self.wakeMACs = wakeMACs
    }

    /// Copy with an updated last-known address (the fingerprint, i.e. the identity, never changes).
    public func reached(at host: String, port: UInt16) -> PairedHost {
        PairedHost(
            name: name, fingerprint: fingerprint, pairedAt: pairedAt,
            lastKnownHost: host, lastKnownPort: port,
            savedHost: savedHost, savedPort: savedPort, wakeMACs: wakeMACs
        )
    }

    /// Copy with a user-chosen address; pass nil and nil to clear it.
    public func withSavedAddress(host: String?, port: UInt16?) -> PairedHost {
        PairedHost(
            name: name, fingerprint: fingerprint, pairedAt: pairedAt,
            lastKnownHost: lastKnownHost, lastKnownPort: lastKnownPort,
            savedHost: host, savedPort: port, wakeMACs: wakeMACs
        )
    }

    /// Copy with the Mac's reported hardware addresses (normalised; invalid ones are dropped).
    public func withWakeMACs(_ addresses: [String]) -> PairedHost {
        var seen = Set<MACAddress>()
        let valid = addresses.compactMap(MACAddress.init).filter { seen.insert($0).inserted }.map(\.description)
        return PairedHost(
            name: name, fingerprint: fingerprint, pairedAt: pairedAt,
            lastKnownHost: lastKnownHost, lastKnownPort: lastKnownPort,
            savedHost: savedHost, savedPort: savedPort, wakeMACs: valid
        )
    }
}
