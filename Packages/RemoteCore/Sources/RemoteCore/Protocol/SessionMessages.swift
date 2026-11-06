import Foundation

/// Optional features a client can ask the Mac for in its hello.
public enum Capability: String, Codable, Sendable, CaseIterable {
    case displays
    case audio
    case virtualDisplay
}

/// iPhone -> Mac, sent once after the connection is up.
public struct ClientHello: Equatable, Sendable {
    public let protocolVersion: Int
    public let capabilities: Set<Capability>

    public init(protocolVersion: Int, capabilities: Set<Capability>) {
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
    }
}

extension ClientHello: Codable {
    private enum CodingKeys: String, CodingKey { case protocolVersion, capabilities }

    /// Capability names from a newer client that this build does not know are skipped, not an error.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let names = try container.decode([String].self, forKey: .capabilities)
        self.init(
            protocolVersion: try container.decode(Int.self, forKey: .protocolVersion),
            capabilities: Set(names.compactMap(Capability.init(rawValue:)))
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(capabilities.map(\.rawValue).sorted(), forKey: .capabilities)
    }
}

/// One display on the Mac. `id` is the display UUID, which survives replugging (numeric IDs do not).
public struct DisplayInfo: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let isMain: Bool

    public init(id: String, name: String, pixelWidth: Int, pixelHeight: Int, isMain: Bool) {
        self.id = id
        self.name = name
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.isMain = isMain
    }
}

/// Mac -> iPhone: what can be streamed and how to wake this Mac.
public struct HostInfo: Codable, Equatable, Sendable {
    public let displays: [DisplayInfo]
    public let selectedID: String?
    /// Hardware addresses for Wake-on-LAN, `aa:bb:cc:dd:ee:ff`.
    public let wakeMACs: [String]
    public let virtualDisplaySupported: Bool

    public init(displays: [DisplayInfo], selectedID: String?, wakeMACs: [String], virtualDisplaySupported: Bool) {
        self.displays = displays
        self.selectedID = selectedID
        self.wakeMACs = wakeMACs
        self.virtualDisplaySupported = virtualDisplaySupported
    }
}

/// iPhone -> Mac: stream this display.
public struct SelectDisplay: Codable, Equatable, Sendable {
    public let displayID: String

    public init(displayID: String) {
        self.displayID = displayID
    }
}
