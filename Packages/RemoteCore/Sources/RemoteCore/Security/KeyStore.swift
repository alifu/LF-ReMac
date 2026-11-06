import Foundation
import os

public enum KeyStoreError: Error, Equatable, Sendable {
    /// Underlying `OSStatus` from Security.framework.
    case keychain(OSStatus)
    case unexpectedItem
    case invalidKey
}

/// Small persistent blobs (paired-device lists etc.) addressed by name.
public protocol KeyStore: Sendable {
    /// Returns nil when nothing is stored under `key`.
    func data(forKey key: String) throws(KeyStoreError) -> Data?
    /// Creates or replaces the value under `key`.
    func set(_ data: Data, forKey key: String) throws(KeyStoreError)
    /// Succeeds when nothing is stored under `key`.
    func removeData(forKey key: String) throws(KeyStoreError)
}

/// Process-local store for tests and previews.
public final class InMemoryKeyStore: KeyStore {
    private let storage: OSAllocatedUnfairLock<[String: Data]>

    public init(_ initial: [String: Data] = [:]) {
        storage = OSAllocatedUnfairLock(initialState: initial)
    }

    public func data(forKey key: String) throws(KeyStoreError) -> Data? {
        storage.withLock { $0[key] }
    }

    public func set(_ data: Data, forKey key: String) throws(KeyStoreError) {
        storage.withLock { $0[key] = data }
    }

    public func removeData(forKey key: String) throws(KeyStoreError) {
        _ = storage.withLock { $0.removeValue(forKey: key) }
    }
}
