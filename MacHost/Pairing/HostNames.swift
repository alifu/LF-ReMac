import Foundation
import RemoteCore
import SystemConfiguration

/// The Mac's names as the pairing flow needs them.
enum HostNames {
    static let fallbackDisplayName = "Mac"

    /// User-visible computer name ("Ali's Mac mini"), also the default Bonjour service name.
    /// Falls back to "Mac" if it is missing or not a valid `DeviceName`.
    static func displayName() -> String {
        let name = SCDynamicStoreCopyComputerName(nil, nil) as String?
        guard let name, DeviceName.isValid(name) else { return fallbackDisplayName }
        return name
    }

    /// `<local host name>.local` for the QR code, so the iPhone can dial the Mac via mDNS.
    static func invitationHost() -> String? {
        guard let local = SCDynamicStoreCopyLocalHostName(nil) as String?, !local.isEmpty else { return nil }
        return "\(local).local"
    }
}
