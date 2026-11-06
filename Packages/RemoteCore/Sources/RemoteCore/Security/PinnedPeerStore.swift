import Foundation
import os

public enum PeerStoreError: Error, Equatable, Sendable {
    case keyStore(KeyStoreError)
    /// Stored bytes could not be decoded. Reads see an empty list; writes are refused until
    /// `resetCorruptedStore()` so the damaged data is never overwritten silently.
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

/// Persists pinned peers as versioned JSON in a `KeyStore`, with an in-memory snapshot so the
/// synchronous `contains` that backs a TLS verify block never touches the Keychain once loaded.
/// Thread-safe: the snapshot and every write are guarded by one lock, so a revocation is visible
/// to the next `contains` as soon as `remove` returns.
///
/// Failure policy:
/// - a Keychain *read error* is never cached: `contains` fails closed, writes throw, and the next
///   call retries the read;
/// - corrupted data reads as empty with `.corrupted` (logged, never a crash) and refuses writes
///   until `resetCorruptedStore()`;
/// - a failed write drops the snapshot so the next call reloads what the Keychain really holds.
///
/// The snapshot assumes this instance is the only writer of `key` in the process.
public final class PinnedPeerStore<Peer: PinnedPeer>: Sendable {
    public static var maxPeers: Int { 32 }
    static var formatVersion: Int { 1 }

    private struct Stored: Codable {
        let version: Int
        let peers: [Peer]
    }

    private let keyStore: any KeyStore
    private let key: String
    /// nil = not loaded (or last load/write failed); a cached snapshot never has a `.keyStore` issue.
    private let cache = OSAllocatedUnfairLock<PeerStoreSnapshot<Peer>?>(initialState: nil)
    private let logger = AppLog.logger(category: "peer-store")

    public init(keyStore: any KeyStore, key: String) {
        self.keyStore = keyStore
        self.key = key
    }

    public func load() -> PeerStoreSnapshot<Peer> {
        cache.withLock { current(&$0) }
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
        try mutate { peers throws(PeerStoreError) in
            let others = peers.filter { $0.fingerprint != peer.fingerprint }
            guard others.count < Self.maxPeers else { throw .tooManyPeers }
            return others + [peer]
        }
    }

    /// Removes the entry with `fingerprint`; succeeds if there is none.
    public func remove(_ fingerprint: DeviceFingerprint) throws(PeerStoreError) {
        try mutate { peers in peers.filter { $0.fingerprint != fingerprint } }
    }

    public func removeAll() throws(PeerStoreError) {
        try cache.lockedState { cached throws(PeerStoreError) in
            try replaceStored(with: nil, cached: &cached)
        }
    }

    /// Deletes stored data that could not be decoded (call only after the user agreed to lose the
    /// list). Does nothing when the data is fine; throws if the Keychain cannot be read.
    public func resetCorruptedStore() throws(PeerStoreError) {
        try cache.lockedState { cached throws(PeerStoreError) in
            let snapshot = current(&cached)
            switch snapshot.issue {
            case .corrupted:
                logger.notice("Resetting corrupted pinned peers data")
                try replaceStored(with: nil, cached: &cached)
            case .keyStore(let error):
                throw .keyStore(error)
            case .encodingFailed, .tooManyPeers, nil:
                return
            }
        }
    }

    // MARK: Private (call with the lock held)

    private func mutate(_ change: ([Peer]) throws(PeerStoreError) -> [Peer]) throws(PeerStoreError) {
        try cache.lockedState { cached throws(PeerStoreError) in
            let snapshot = current(&cached)
            if let issue = snapshot.issue { throw issue }
            try replaceStored(with: try change(snapshot.peers), cached: &cached)
        }
    }

    /// The cached snapshot, loading it first if needed. Only successful loads are cached.
    private func current(_ cached: inout PeerStoreSnapshot<Peer>?) -> PeerStoreSnapshot<Peer> {
        if let cached { return cached }
        let snapshot = read()
        if case .keyStore = snapshot.issue { return snapshot }
        cached = snapshot
        return snapshot
    }

    private func read() -> PeerStoreSnapshot<Peer> {
        let data: Data?
        do {
            data = try keyStore.data(forKey: key)
        } catch {
            logger.error("Reading pinned peers failed: \(String(describing: error), privacy: .public)")
            return PeerStoreSnapshot(peers: [], issue: .keyStore(error))
        }
        guard let data else { return PeerStoreSnapshot(peers: [], issue: nil) }
        guard let peers = Self.decode(data) else {
            logger.error("Pinned peers data is corrupted; treating it as empty and refusing writes")
            return PeerStoreSnapshot(peers: [], issue: .corrupted)
        }
        return PeerStoreSnapshot(peers: peers, issue: nil)
    }

    /// Writes `peers` (nil deletes the item) and updates the snapshot; on failure drops it.
    private func replaceStored(with peers: [Peer]?, cached: inout PeerStoreSnapshot<Peer>?) throws(PeerStoreError) {
        cached = nil
        if let peers {
            try write(peers)
        } else {
            try removeStored()
        }
        cached = PeerStoreSnapshot(peers: peers ?? [], issue: nil)
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
