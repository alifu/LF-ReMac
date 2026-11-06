import os

extension OSAllocatedUnfairLock where State == () {
    /// `withLock` that keeps the body's typed error (the stdlib variant erases it to `any Error`).
    func locked<T, E: Error>(_ body: () throws(E) -> T) throws(E) -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

/// One process-wide lock for every Keychain call made by RemoteCore.
///
/// The macOS file-based keychain misbehaves under concurrent `SecItem*` / `SecKeyCreateRandomKey`
/// calls from one process (observed: spurious `errSecDuplicateItem`, lost reads, "failed to generate
/// CDSA key"). Keychain calls are short, so serializing them costs nothing noticeable.
enum KeychainAccess {
    private static let lock = OSAllocatedUnfairLock()

    static func serialized<T, E: Error>(_ body: () throws(E) -> T) throws(E) -> T {
        try lock.locked(body)
    }
}
