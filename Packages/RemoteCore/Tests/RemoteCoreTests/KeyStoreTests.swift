import Foundation
import Testing
@testable import RemoteCore

struct KeyStoreTests {
    /// Runs every case against both implementations; the Keychain one uses a unique service.
    static let stores: [String] = ["memory", "keychain"]

    private func withStore(_ kind: String, _ body: (any KeyStore) throws -> Void) throws {
        guard kind == "keychain" else { return try body(InMemoryKeyStore()) }
        let store = KeychainKeyStore(service: "com.alifu.lfremac.tests.\(UUID().uuidString)")
        defer {
            try? store.removeData(forKey: "a")
            try? store.removeData(forKey: "b")
        }
        try body(store)
    }

    @Test(arguments: stores)
    func readsNilForMissingKey(kind: String) throws {
        try withStore(kind) { store throws in #expect(try store.data(forKey: "a") == nil) }
    }

    @Test(arguments: stores)
    func storesReplacesAndRemovesValues(kind: String) throws {
        try withStore(kind) { store in
            try store.set(Data([1, 2, 3]), forKey: "a")
            #expect(try store.data(forKey: "a") == Data([1, 2, 3]))

            try store.set(Data([9]), forKey: "a")
            #expect(try store.data(forKey: "a") == Data([9]))

            try store.removeData(forKey: "a")
            #expect(try store.data(forKey: "a") == nil)
        }
    }

    @Test(arguments: stores)
    func keysAreIndependent(kind: String) throws {
        try withStore(kind) { store in
            try store.set(Data([1]), forKey: "a")
            try store.set(Data([2]), forKey: "b")

            #expect(try store.data(forKey: "a") == Data([1]))
            #expect(try store.data(forKey: "b") == Data([2]))
        }
    }

    @Test(arguments: stores)
    func removingMissingKeySucceeds(kind: String) throws {
        try withStore(kind) { store throws in try store.removeData(forKey: "b") }
    }

    @Test func keychainServicesAreIsolated() throws {
        let first = KeychainKeyStore(service: "com.alifu.lfremac.tests.\(UUID().uuidString)")
        let second = KeychainKeyStore(service: "com.alifu.lfremac.tests.\(UUID().uuidString)")
        defer { try? first.removeData(forKey: "a") }

        try first.set(Data([7]), forKey: "a")

        #expect(try second.data(forKey: "a") == nil)
    }

    @Test func keychainRejectsEmptyAndOverlongKeys() {
        let store = KeychainKeyStore(service: "com.alifu.lfremac.tests.\(UUID().uuidString)")

        #expect(throws: KeyStoreError.invalidKey) { try store.data(forKey: "") }
        #expect(throws: KeyStoreError.invalidKey) {
            try store.set(Data(), forKey: String(repeating: "k", count: KeychainKeyStore.maxKeyLength + 1))
        }
    }
}
