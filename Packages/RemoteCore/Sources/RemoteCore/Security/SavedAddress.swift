import Foundation

/// Why a user-typed address for a paired Mac was refused.
public enum SavedAddressError: Error, Equatable, Sendable {
    case emptyHost
    case hostContainsSpaces
    case hostTooLong
    case invalidPort

    public var message: String {
        switch self {
        case .emptyHost: "Enter an IP address or host name."
        case .hostContainsSpaces: "The address cannot contain spaces."
        case .hostTooLong: "The address is longer than 253 characters."
        case .invalidPort: "The port must be a number from 1 to 65535."
        }
    }
}

/// A manual address (e.g. a Tailscale IP or MagicDNS name) where a paired Mac can be reached.
public struct SavedAddress: Equatable, Sendable {
    public static let maxHostLength = 253
    public static let portRange: ClosedRange<UInt16> = 1...UInt16.max
    public static let defaultPort: UInt16 = 47800

    public let host: String
    public let port: UInt16

    /// Validates the text typed into the address form. Host is trimmed; the port must be in `portRange`.
    public static func validate(hostText: String, portText: String) -> Result<(host: String, port: UInt16), SavedAddressError> {
        let host = hostText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return .failure(.emptyHost) }
        guard !host.contains(where: \.isWhitespace) else { return .failure(.hostContainsSpaces) }
        guard host.count <= maxHostLength else { return .failure(.hostTooLong) }
        guard let port = UInt16(portText.trimmingCharacters(in: .whitespacesAndNewlines)),
              portRange.contains(port) else {
            return .failure(.invalidPort)
        }
        return .success((host: host, port: port))
    }
}
