import Foundation
import Network
import os
import RemoteCore
import Testing

/// Proves identities created by the iOS Keychain path work for pinned mutual TLS 1.3 on iOS.
@Suite(.serialized)
struct IdentityTLSTests {
    @Test func iOSIdentitiesCompleteAPinnedMutualTLSHandshake() async throws {
        let namespaces = ["host", "phone"].map { "com.alifu.lfremac.tests.\($0).\(UUID().uuidString)" }
        defer { namespaces.forEach { try? DeviceIdentity.delete(namespace: $0) } }
        let host = try DeviceIdentity.loadOrCreate(deviceName: "Sim Host", namespace: namespaces[0])
        let phone = try DeviceIdentity.loadOrCreate(deviceName: "Sim Phone", namespace: namespaces[1])

        let serverParameters = try TLSParameters.server(identity: host) { $0 == phone.fingerprint }
        serverParameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: serverParameters)
        let seenByServer = OSAllocatedUnfairLock<DeviceFingerprint?>(initialState: nil)
        let listenerReady = OSAllocatedUnfairLock(initialState: false)
        let queue = DispatchQueue(label: "ios-tls-test")
        listener.stateUpdateHandler = { state in
            if case .ready = state { listenerReady.withLock { $0 = true } }
        }
        listener.newConnectionHandler = { connection in
            connection.stateUpdateHandler = { state in
                if case .ready = state { seenByServer.withLock { $0 = TLSParameters.peerFingerprint(of: connection) } }
            }
            connection.start(queue: queue)
        }
        listener.start(queue: queue)
        defer { listener.cancel() }
        try await waitUntil { listenerReady.withLock { $0 } }

        let client = NWConnection(
            host: "127.0.0.1", port: listener.port ?? .any,
            using: try TLSParameters.client(identity: phone) { $0 == host.fingerprint }
        )
        client.start(queue: queue)
        defer { client.cancel() }

        try await waitUntil { seenByServer.withLock { $0 } != nil }
        #expect(seenByServer.withLock { $0 } == phone.fingerprint)
        #expect(TLSParameters.peerFingerprint(of: client) == host.fingerprint)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}
