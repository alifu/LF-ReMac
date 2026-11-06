import Foundation
import Network
import os
import RemoteCore
@testable import MacHost

/// Collects every server event so tests can wait for, count and rule out events.
final class EventRecorder: Sendable {
    private let recorded = OSAllocatedUnfairLock<[StreamServerEvent]>(initialState: [])
    private let task: Task<Void, Never>

    init(_ events: AsyncStream<StreamServerEvent>) {
        let recorded = recorded
        task = Task { for await event in events { recorded.withLock { $0.append(event) } } }
    }

    var events: [StreamServerEvent] { recorded.withLock { $0 } }

    func count(where predicate: (StreamServerEvent) -> Bool) -> Int {
        events.filter(predicate).count
    }

    func contains(_ event: StreamServerEvent) -> Bool {
        events.contains(event)
    }

    func waitFor(_ event: StreamServerEvent, count: Int = 1) async throws {
        try await eventually { self.events.filter { $0 == event }.count >= count }
    }

    func waitFor(count: Int = 1, where predicate: @escaping (StreamServerEvent) -> Bool) async throws {
        try await eventually { self.count(where: predicate) >= count }
    }

    func stop() { task.cancel() }
}

/// A real `StreamServer` on loopback with a test host identity, in-memory store and test clock.
struct ServerHarness {
    static let shortLimits = StreamServerLimits(
        maxHandshaking: 8, maxPairingConnections: 2, handshakeTimeout: 5, pairRequestTimeout: 0.6, pairingLinger: 1
    )

    let host: DeviceIdentity
    let store: PairedDeviceStore
    let coordinator: PairingCoordinator
    let clock: TestClock
    let server: StreamServer
    let recorder: EventRecorder
    let port: UInt16

    var endpoint: NWEndpoint {
        .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
    }

    /// Host identity plus `phones` phone identities; everything is torn down afterwards.
    static func run(
        phones: [String],
        limits: StreamServerLimits = shortLimits,
        _ body: (ServerHarness, [DeviceIdentity]) async throws -> Void
    ) async throws {
        try await TestIdentity.withIdentities(["Test Mac"] + phones) { identities in
            let harness = try await make(host: identities[0], limits: limits)
            defer {
                harness.server.stop()
                harness.recorder.stop()
            }
            try await body(harness, Array(identities.dropFirst()))
        }
    }

    private static func make(host: DeviceIdentity, limits: StreamServerLimits) async throws -> ServerHarness {
        let clock = TestClock()
        let store = PairedDeviceStore(keyStore: InMemoryKeyStore(), key: "paired-devices")
        let coordinator = PairingCoordinator(
            hostFingerprint: host.fingerprint, invitationHost: "127.0.0.1", clock: clock.function
        )
        let server = StreamServer(
            identity: host, store: store, coordinator: coordinator, hostName: "Test Mac",
            serviceType: nil, port: .any, limits: limits
        )
        let recorder = EventRecorder(server.events)
        try server.start()
        var port: UInt16?
        try await eventually {
            port = recorder.events.compactMap { if case .ready(let port) = $0 { port } else { nil } }.first
            return port != nil
        }
        guard let port else { throw LoopbackError.serverNeverReady }
        return ServerHarness(
            host: host, store: store, coordinator: coordinator, clock: clock, server: server, recorder: recorder, port: port
        )
    }

    func pair(_ phone: DeviceIdentity, name: String = "Test iPhone") throws {
        try store.add(PairedDevice(name: name, fingerprint: phone.fingerprint, pairedAt: clock.now))
    }

    /// Runs the iPhone's real pairing handshake against this server.
    func runPairing(
        _ phone: DeviceIdentity, secret: PairingSecret, expected: DeviceFingerprint?
    ) async throws(PairingHandshakeError) -> PairingHandshakeResult {
        try await PairingHandshake.run(
            endpoint: endpoint, identity: phone, secret: secret, expectedHostFingerprint: expected,
            deviceName: "Test iPhone", timeout: .seconds(5)
        )
    }

    /// TLS client that pins this server's identity.
    func connect(_ phone: DeviceIdentity) throws -> TLSTestClient {
        try TLSTestClient(port: port, identity: phone, pinning: host.fingerprint)
    }
}
