import Foundation
import RemoteCore
import UIKit

/// This iPhone's TLS identity (created lazily on first use) and its paired-Mac store.
/// Thread-safe; inject a test namespace and an in-memory `KeyStore` in tests.
final class PhoneCredentials: @unchecked Sendable {
    static let pairedHostsService = "com.alifu.lfremac.client.paired-hosts"
    static let pairedHostsKey = "paired-hosts"
    static let fallbackDeviceName = "iPhone"

    let hostStore: PairedHostStore
    /// Name sent to the Mac when pairing; always a valid `DeviceName`.
    let deviceName: String
    private let namespace: String
    /// Guards `cached`; held across `loadOrCreate` so two callers never create two keys.
    private let lock = NSLock()
    private var cached: DeviceIdentity?

    init(namespace: String = DeviceIdentity.defaultNamespace, keyStore: any KeyStore, deviceName: String) {
        self.namespace = namespace
        self.hostStore = PairedHostStore(keyStore: keyStore, key: Self.pairedHostsKey)
        self.deviceName = Self.validDeviceName(deviceName)
    }

    @MainActor
    static func live() -> PhoneCredentials {
        PhoneCredentials(keyStore: KeychainKeyStore(service: pairedHostsService), deviceName: UIDevice.current.name)
    }

    /// Loads or, on first use, creates the identity. Failures are not cached, so a later call retries.
    func identity() throws(IdentityError) -> DeviceIdentity {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let identity = try DeviceIdentity.loadOrCreate(deviceName: deviceName, namespace: namespace)
        cached = identity
        return identity
    }

    static func validDeviceName(_ name: String) -> String {
        DeviceName.isValid(name) ? name : fallbackDeviceName
    }
}
