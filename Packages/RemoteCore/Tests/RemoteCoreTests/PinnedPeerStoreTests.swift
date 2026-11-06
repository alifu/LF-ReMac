import Foundation
import Testing
@testable import RemoteCore

/// Key store whose reads fail, to simulate a locked or broken Keychain.
private final class FailingKeyStore: KeyStore {
    func data(forKey key: String) throws(KeyStoreError) -> Data? { throw .keychain(-25308) }
    func set(_ data: Data, forKey key: String) throws(KeyStoreError) { throw .keychain(-25308) }
    func removeData(forKey key: String) throws(KeyStoreError) { throw .keychain(-25308) }
}

/// Forwards to an in-memory store, counts reads and can fail reads or writes on demand.
private final class CountingKeyStore: KeyStore, @unchecked Sendable {
    private let backing: InMemoryKeyStore
    private let lock = NSLock()
    private var readCount = 0
    private var shouldFailReads = false
    private var shouldFailWrites = false

    init(backing: InMemoryKeyStore = InMemoryKeyStore()) {
        self.backing = backing
    }

    var reads: Int { lock.withLock { readCount } }
    var failReads: Bool {
        get { lock.withLock { shouldFailReads } }
        set { lock.withLock { shouldFailReads = newValue } }
    }
    var failWrites: Bool {
        get { lock.withLock { shouldFailWrites } }
        set { lock.withLock { shouldFailWrites = newValue } }
    }

    func data(forKey key: String) throws(KeyStoreError) -> Data? {
        let fail = lock.withLock { () -> Bool in
            readCount += 1
            return shouldFailReads
        }
        if fail { throw .keychain(-25308) }
        return try backing.data(forKey: key)
    }

    func set(_ data: Data, forKey key: String) throws(KeyStoreError) {
        if failWrites { throw .keychain(-25308) }
        try backing.set(data, forKey: key)
    }

    func removeData(forKey key: String) throws(KeyStoreError) {
        if failWrites { throw .keychain(-25308) }
        try backing.removeData(forKey: key)
    }
}

struct PinnedPeerStoreTests {
    private let keyStore = InMemoryKeyStore()
    private let key = "paired-devices"
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    private var store: PairedDeviceStore { PairedDeviceStore(keyStore: keyStore, key: key) }
    private func device(_ fingerprint: DeviceFingerprint, _ name: String = "iPhone") -> PairedDevice {
        PairedDevice(name: name, fingerprint: fingerprint, pairedAt: date)
    }

    @Test func startsEmptyWithoutIssues() {
        let snapshot = store.load()

        #expect(snapshot.peers.isEmpty)
        #expect(snapshot.issue == nil)
        #expect(!store.contains(Fixtures.phone))
    }

    @Test func addedDevicesPersistAcrossInstances() throws {
        try store.add(device(Fixtures.phone))
        try store.add(device(Fixtures.attacker, "iPad"))

        let reopened = PairedDeviceStore(keyStore: keyStore, key: key)

        #expect(reopened.all() == [device(Fixtures.phone), device(Fixtures.attacker, "iPad")])
        #expect(reopened.contains(Fixtures.phone))
        #expect(reopened.peer(with: Fixtures.attacker)?.name == "iPad")
    }

    @Test func addingTheSameFingerprintReplacesTheEntry() throws {
        try store.add(device(Fixtures.phone, "Old"))
        try store.add(device(Fixtures.phone, "New"))

        #expect(store.all() == [device(Fixtures.phone, "New")])
    }

    @Test func removeRevokesOnlyThatDevice() throws {
        try store.add(device(Fixtures.phone))
        try store.add(device(Fixtures.attacker))

        try store.remove(Fixtures.phone)
        try store.remove(Fixtures.host)

        #expect(!store.contains(Fixtures.phone))
        #expect(store.contains(Fixtures.attacker))
    }

    @Test(arguments: [Data("not json".utf8), Data("{\"version\":2,\"peers\":[]}".utf8), Data("{\"version\":1,\"peers\":[{\"name\":\"x\"}]}".utf8), Data([0xFF])])
    func corruptedDataReadsAsEmptyAndIsReported(data: Data) throws {
        try keyStore.set(data, forKey: key)

        let snapshot = store.load()

        #expect(snapshot.peers.isEmpty)
        #expect(snapshot.issue == .corrupted)
        #expect(!store.contains(Fixtures.phone))
    }

    @Test func corruptedDataRefusesWritesUntilExplicitlyReset() throws {
        let garbage = Data("garbage".utf8)
        try keyStore.set(garbage, forKey: key)
        let corrupted = store

        #expect(throws: PeerStoreError.corrupted) { try corrupted.add(device(Fixtures.phone)) }
        #expect(throws: PeerStoreError.corrupted) { try corrupted.remove(Fixtures.phone) }
        #expect(try keyStore.data(forKey: key) == garbage)

        try corrupted.resetCorruptedStore()
        try corrupted.add(device(Fixtures.phone))

        #expect(corrupted.load().issue == nil)
        #expect(corrupted.all() == [device(Fixtures.phone)])
    }

    @Test func resetLeavesHealthyDataAloneAndFailsOnKeychainErrors() throws {
        try store.add(device(Fixtures.phone))

        try store.resetCorruptedStore()

        #expect(store.contains(Fixtures.phone))
        let failing = PairedDeviceStore(keyStore: FailingKeyStore(), key: key)
        #expect(throws: PeerStoreError.keyStore(.keychain(-25308))) { try failing.resetCorruptedStore() }
    }

    @Test func lookupsAfterTheFirstLoadDoNotTouchTheKeyStore() throws {
        let counting = CountingKeyStore()
        let cached = PairedDeviceStore(keyStore: counting, key: key)
        try cached.add(device(Fixtures.phone))
        let readsAfterAdd = counting.reads

        for _ in 0..<10 { _ = cached.contains(Fixtures.phone) }
        _ = cached.peer(with: Fixtures.phone)
        _ = cached.all()

        #expect(readsAfterAdd == 1)
        #expect(counting.reads == 1)
    }

    @Test func revocationIsVisibleToTheNextLookupAtOnce() throws {
        let cached = store
        try cached.add(device(Fixtures.phone))
        #expect(cached.contains(Fixtures.phone))

        try cached.remove(Fixtures.phone)

        #expect(!cached.contains(Fixtures.phone))
        try cached.add(device(Fixtures.attacker))
        try cached.removeAll()
        #expect(!cached.contains(Fixtures.attacker))
    }

    @Test func keychainReadFailureIsNotCachedAndTheNextCallRetries() throws {
        let flaky = CountingKeyStore(backing: keyStore)
        try PairedDeviceStore(keyStore: keyStore, key: key).add(device(Fixtures.phone))
        flaky.failReads = true
        let cached = PairedDeviceStore(keyStore: flaky, key: key)

        #expect(!cached.contains(Fixtures.phone))
        #expect(throws: PeerStoreError.keyStore(.keychain(-25308))) { try cached.add(device(Fixtures.attacker)) }
        flaky.failReads = false

        #expect(cached.contains(Fixtures.phone))
        #expect(cached.load().issue == nil)
    }

    @Test func failedWriteDropsTheSnapshotAndReloads() throws {
        let flaky = CountingKeyStore(backing: keyStore)
        let cached = PairedDeviceStore(keyStore: flaky, key: key)
        try cached.add(device(Fixtures.phone))
        flaky.failWrites = true

        #expect(throws: PeerStoreError.keyStore(.keychain(-25308))) { try cached.remove(Fixtures.phone) }
        let readsBefore = flaky.reads
        flaky.failWrites = false

        #expect(cached.contains(Fixtures.phone))
        #expect(flaky.reads == readsBefore + 1)
    }

    @Test func duplicateFingerprintsInStoredDataAreTreatedAsCorrupted() throws {
        let duplicated = "{\"version\":1,\"peers\":[{\"name\":\"a\",\"fingerprint\":\"\(Fixtures.phone)\",\"pairedAt\":0},{\"name\":\"b\",\"fingerprint\":\"\(Fixtures.phone)\",\"pairedAt\":0}]}"
        try keyStore.set(Data(duplicated.utf8), forKey: key)

        #expect(store.load().issue == .corrupted)
    }

    @Test func keychainFailureFailsClosedAndNeverOverwrites() {
        let failing = PairedDeviceStore(keyStore: FailingKeyStore(), key: key)

        #expect(!failing.contains(Fixtures.phone))
        #expect(failing.load().issue == .keyStore(.keychain(-25308)))
        #expect(throws: PeerStoreError.keyStore(.keychain(-25308))) { try failing.add(device(Fixtures.phone)) }
    }

    @Test func refusesToGrowBeyondTheLimit() throws {
        for index in 0..<PairedDeviceStore.maxPeers {
            try store.add(device(Fixtures.fingerprint(UInt8(index + 100))))
        }

        #expect(throws: PeerStoreError.tooManyPeers) { try store.add(device(Fixtures.fingerprint(1))) }
        try store.add(device(Fixtures.fingerprint(100), "replacement is fine"))
    }

    @Test func removeAllClearsTheList() throws {
        try store.add(device(Fixtures.phone))

        try store.removeAll()

        #expect(store.all().isEmpty)
    }

    @Test func pairedHostStoreKeepsTheLastKnownAddress() throws {
        let hosts = PairedHostStore(keyStore: keyStore, key: "paired-host")
        let mac = PairedHost(name: "Mac mini", fingerprint: Fixtures.host, pairedAt: date, lastKnownHost: nil, lastKnownPort: nil)

        try hosts.add(mac)
        try hosts.add(mac.reached(at: "100.64.0.7", port: 47800))

        let stored = try #require(hosts.peer(with: Fixtures.host))
        #expect(hosts.all().count == 1)
        #expect(stored.lastKnownHost == "100.64.0.7")
        #expect(stored.lastKnownPort == 47800)
        #expect(stored.pairedAt == date)
    }

    @Test func worksOnTheRealKeychain() throws {
        let keychain = KeychainKeyStore(service: "com.alifu.lfremac.tests.\(UUID().uuidString)")
        defer { try? keychain.removeData(forKey: key) }
        let keychainStore = PairedDeviceStore(keyStore: keychain, key: key)

        try keychainStore.add(device(Fixtures.phone))

        #expect(PairedDeviceStore(keyStore: keychain, key: key).contains(Fixtures.phone))
    }
}
