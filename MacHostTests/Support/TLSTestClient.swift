import Foundation
import Network
import os
import RemoteCore

/// Minimal mutual-TLS client speaking the frame protocol over a real socket (plays the iPhone).
final class TLSTestClient: Sendable {
    private struct Status {
        var isReady = false
        var isClosed = false
        var decoder = FrameDecoder()
        var frames: [Frame] = []
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "loopback.tls-client")
    private let status = OSAllocatedUnfairLock(initialState: Status())

    init(port: UInt16, identity: DeviceIdentity, pinning server: DeviceFingerprint) throws {
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
        connection = NWConnection(to: endpoint, using: try TLSParameters.client(identity: identity) { $0 == server })
        connection.stateUpdateHandler = { [status] state in
            switch state {
            case .ready: status.withLock { $0.isReady = true }
            case .failed, .cancelled, .waiting: status.withLock { $0.isClosed = true }
            default: break
            }
        }
        connection.start(queue: queue)
        pump()
    }

    var isReady: Bool { status.withLock { $0.isReady } }
    var isClosed: Bool { status.withLock { $0.isClosed } }
    var frames: [Frame] { status.withLock { $0.frames } }

    func waitUntilReady() async throws {
        try await eventually { isReady || isClosed }
        guard isReady else { throw LoopbackError.timedOut }
    }

    func waitUntilClosed(timeout: Duration = .seconds(3)) async throws {
        try await eventually(timeout: timeout) { isClosed }
    }

    func send(_ frame: Frame) {
        sendRaw(FrameEncoder.encode(frame))
    }

    func sendRaw(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    func receive(count: Int) async throws -> [Frame] {
        try await eventually { frames.count >= count }
        return Array(frames.prefix(count))
    }

    func close() {
        connection.cancel()
    }

    private func pump() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data { append(data) }
            if error != nil || done {
                status.withLock { $0.isClosed = true }
            } else {
                pump()
            }
        }
    }

    private func append(_ data: Data) {
        status.withLock { status in
            if let decoded = try? status.decoder.append(data) { status.frames += decoded }
        }
    }
}
