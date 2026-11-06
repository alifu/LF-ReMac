import Foundation
import Security

/// `KeyStore` backed by generic-password Keychain items (`service` = namespace, `account` = key).
///
/// Items are `kSecAttrAccessibleAfterFirstUnlock` so a locked-but-booted device can still connect.
/// On macOS this uses the file-based login keychain (no data-protection keychain entitlement needed);
/// on iOS it uses the app's keychain access group.
public struct KeychainKeyStore: KeyStore {
    public static let maxKeyLength = 128

    public let service: String

    public init(service: String) {
        self.service = service
    }

    public func data(forKey key: String) throws(KeyStoreError) -> Data? {
        try KeychainAccess.serialized { () throws(KeyStoreError) in try read(key) }
    }

    public func set(_ data: Data, forKey key: String) throws(KeyStoreError) {
        try KeychainAccess.serialized { () throws(KeyStoreError) in try write(data, key) }
    }

    public func removeData(forKey key: String) throws(KeyStoreError) {
        try KeychainAccess.serialized { () throws(KeyStoreError) in try delete(key) }
    }

    // MARK: Private (call under `KeychainAccess`)

    private func read(_ key: String) throws(KeyStoreError) -> Data? {
        var query = try baseQuery(key)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw .unexpectedItem }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw .keychain(status)
        }
    }

    private func write(_ data: Data, _ key: String) throws(KeyStoreError) {
        let query = try baseQuery(key)
        let update: [CFString: Any] = [kSecValueData: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            try add(data, query: query)
        default:
            throw .keychain(status)
        }
    }

    private func delete(_ key: String) throws(KeyStoreError) {
        let status = SecItemDelete(try baseQuery(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw .keychain(status) }
    }

    private func add(_ data: Data, query: [CFString: Any]) throws(KeyStoreError) {
        var attributes = query
        attributes[kSecValueData] = data
        attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw .keychain(status) }
    }

    private func baseQuery(_ key: String) throws(KeyStoreError) -> [CFString: Any] {
        guard !key.isEmpty, key.count <= Self.maxKeyLength, !service.isEmpty else { throw .invalidKey }
        return [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key
        ]
    }
}
