import Foundation

/// Network values both apps must agree on.
public enum NetworkDefaults {
    /// Bonjour service type the Mac host advertises and the iPhone browses for.
    public static let bonjourServiceType = "_lfremac._tcp"
    /// Fixed TCP port so a Mac can also be reached by address (e.g. Tailscale) without Bonjour.
    public static let port: UInt16 = 47800
}
