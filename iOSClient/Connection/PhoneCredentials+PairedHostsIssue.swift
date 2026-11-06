import Foundation
import RemoteCore

extension PhoneCredentials {
    /// Why the paired-Macs list could not be read (nil when it is fine). While the list is damaged
    /// nothing can be paired; offer `resetPairedHosts()` after the user confirms.
    var pairedHostsIssue: String? {
        hostStore.load().issue.map(Self.message(for:))
    }

    /// Deletes a damaged paired-Macs list so pairing works again. Call only after the user agreed;
    /// does nothing when the list is fine.
    func resetPairedHosts() throws(PeerStoreError) {
        try hostStore.resetCorruptedStore()
    }

    private static func message(for issue: PeerStoreError) -> String {
        switch issue {
        case .corrupted:
            "The list of paired Macs is damaged. Reset it, then pair your Macs again."
        case .keyStore:
            "The list of paired Macs could not be read from the Keychain."
        case .encodingFailed, .tooManyPeers:
            "The list of paired Macs could not be read."
        }
    }
}
