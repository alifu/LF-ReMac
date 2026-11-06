import Foundation
import os

public enum PeerStoreError: Error, Equatable, Sendable {
    case keyStore(KeyStoreError)
    /// Stored bytes could not be decoded; the store treats them as empty.
    case corrupted
    case encodingFailed
    case tooManyPeers
}

/// Result of reading the store: the peers, plus the problem if the stored data was unusable.
public struct PeerStoreSnapshot<Peer: PinnedPeer>: Sendable {
    public let peers: [Peer]
    public let issue: PeerStoreError?
}

public typealias PairedDeviceStore = PinnedPeerStore<PairedDevice>
public typealias PairedHostStore = PinnedPeerStore<PairedHost>

/// Persists pinned peers as versioned JSON in a `KeyStore`. Thread-safe: every operation reads the
/// current value under a lock, so the synchronous `contains` can back a TLS verify block.
///
/// Failure policy: corrupted data reads as empty (reported in `load().issue` and logged, never a
/// crash); a Keychain *read error* is not treated as empty for writes, so a transient failure cannot
/// wipe the list. `contains` fails closed.
public final class PinnedPeerStore<Peer: PinnedPeer>: Sendable {
    public static var maxPeers: Int { 32 }
    static var formatVersion: Int { 1 }

    private struct Stored: Codable {
        let version: Int
        let peers: [Peer]
    }

    private let keyStore: any KeyStore
    private let key: String
    private let lock = OSAllocatedUnfairLock()
    private let logger = AppLog.logger(category: "peer-store")

    public init(keyStore: any KeyStore, key: String) {
        self.keyStore = keyStore
        self.key = key
    }

    public func load() -> PeerStoreSnapshot<Peer> {
        lock.withLock { snapshot() }
    }

    public func all() -> [Peer] {
        load().peers
    }

    public func contains(_ fingerprint: DeviceFingerprint) -> Bool {
        all().contains { $0.fingerprint == fingerprint }
    }

    public func peer(with fingerprint: DeviceFingerprint) -> Peer? {
        all().first { $0.fingerprint == fingerprint }
    }

    /// Adds `peer`, replacing any entry with the same fingerprint.
    public func add(_ peer: Peer) throws(PeerStoreError) {
        try lock.locked { () throws(PeerStoreError) in
            let others = try currentPeersForWrite().filter { $0.fingerprint != peer.fingerprint }
            guard others.count < Self.maxPeers else { throw .tooManyPeers }
            try write(others + [peer])
        }
    }

    /// Removes the entry with `fingerprint`; succeeds if there is none.
    public func remove(_ fingerprint: DeviceFingerprint) throws(PeerStoreError) {
        try lock.locked { () throws(PeerStoreError) in
            try write(try currentPeersForWrite().filter { $0.fingerprint != fingerprint })
        }
    }

    public func removeAll() throws(PeerStoreError) {
        try lock.locked { () throws(PeerStoreError) in try removeStored() }
    }

    // MARK: Private (call with the lock held)

    private func snapshot() -> PeerStoreSnapshot<Peer> {
        let data: Data?
        do {
            data = try keyStore.data(forKey: key)
        } catch {
            logger.error("Reading pinned peers failed: \(String(describing: error), privacy: .public)")
            return PeerStoreSnapshot(peers: [], issue: .keyStore(error))
        }
        guard let data else { return PeerStoreSnapshot(peers: [], issue: nil) }
        guard let peers = Self.decode(data) else {
            logger.error("Pinned peers data is corrupted; treating it as empty")
            return PeerStoreSnapshot(peers: [], issue: .corrupted)
        }
        return PeerStoreSnapshot(peers: peers, issue: nil)
    }

    private func currentPeersForWrite() throws(PeerStoreError) -> [Peer] {
        let current = snapshot()
        if case .keyStore(let error) = current.issue { throw .keyStore(error) }
        return current.peers
    }

    private func write(_ peers: [Peer]) throws(PeerStoreError) {
        let data: Data
        do {
            data = try JSONEncoder().encode(Stored(version: Self.formatVersion, peers: peers))
        } catch {
            throw .encodingFailed
        }
        do {
            try keyStore.set(data, forKey: key)
        } catch {
            throw .keyStore(error)
        }
    }

    private func removeStored() throws(PeerStoreError) {
        do {
            try keyStore.removeData(forKey: key)
        } catch {
            throw .keyStore(error)
        }
    }

    private static func decode(_ data: Data) -> [Peer]? {
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.version == formatVersion,
              stored.peers.count <= maxPeers,
              Set(stored.peers.map(\.fingerprint)).count == stored.peers.count else {
            return nil
        }
        return stored.peers
    }
}
