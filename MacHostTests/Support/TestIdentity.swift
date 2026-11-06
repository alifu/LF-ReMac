import Foundation
import os
import RemoteCore
@testable import MacHost

/// Real Keychain identities under unique throw-away namespaces, always deleted afterwards.
/// Never touches the app's real identity (`DeviceIdentity.defaultNamespace`).
enum TestIdentity {
    static func uniqueNamespace() -> String {
        "com.alifu.lfremac.tests.\(UUID().uuidString)"
    }

    /// Creates `names.count` identities, runs `body`, then deletes every one of them.
    static func withIdentities<T>(
        _ names: [String],
        isolation: isolated (any Actor)? = #isolation,
        _ body: ([DeviceIdentity]) async throws -> T) async throws -> T {
        let namespaces = names.map { _ in uniqueNamespace() }
        defer { namespaces.forEach { try? DeviceIdentity.delete(namespace: $0) } }
        let identities = try zip(names, namespaces).map { name, namespace in
            try DeviceIdentity.loadOrCreate(deviceName: name, namespace: namespace)
        }
        return try await body(identities)
    }
}

/// Manually advanced clock for pairing-window expiry.
final class TestClock: Sendable {
    private let current = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_800_000_000))

    var now: Date { current.withLock { $0 } }

    func advance(by interval: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(interval) }
    }

    var function: PairingCoordinator.Clock {
        { [self] in now }
    }
}

enum LoopbackError: Error {
    case serverNeverReady
    case timedOut
}

/// Polls `condition` every 10 ms until it holds or `timeout` passes.
func eventually(
    timeout: Duration = .seconds(5),
    isolation: isolated (any Actor)? = #isolation,
    _ condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { throw LoopbackError.timedOut }
        try await Task.sleep(for: .milliseconds(10))
    }
}
