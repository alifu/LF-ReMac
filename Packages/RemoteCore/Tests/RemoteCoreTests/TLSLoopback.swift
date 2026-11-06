import Foundation
import Network
import os
@testable import RemoteCore

/// Resumes a continuation at most once (state callbacks, receive callbacks and timeouts race).
final class OneShot<Value: Sendable>: Sendable {
    private let continuation: OSAllocatedUnfairLock<CheckedContinuation<Value, Never>?>

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = OSAllocatedUnfairLock(initialState: continuation)
    }

    func resume(_ value: Value) {
        let pending = continuation.withLock { current -> CheckedContinuation<Value, Never>? in
            defer { current = nil }
            return current
        }
        pending?.resume(returning: value)
    }
}

/// In-process TLS echo server on 127.0.0.1 that records which peers completed the handshake.
final class TLSEchoServer: Sendable {
    let listener: NWListener
    private let queue = DispatchQueue(label: "tls-echo-server")
    private let acceptedPeers = OSAllocatedUnfairLock<[DeviceFingerprint?]>(initialState: [])

    init(parameters: NWParameters) throws {
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    var readyPeerFingerprints: [DeviceFingerprint?] { acceptedPeers.withLock { $0 } }

    func start() async -> UInt16? {
        listener.newConnectionHandler = { [self] connection in accept(connection) }
        return await withCheckedContinuation { continuation in
            let once = OneShot(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: once.resume(self.listener.port?.rawValue)
                case .failed, .cancelled: once.resume(nil)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [self] state in
            if case .ready = state {
                let peer = TLSParameters.peerFingerprint(of: connection)
                acceptedPeers.withLock { $0.append(peer) }
                echo(on: connection)
            }
        }
        connection.start(queue: queue)
    }

    private func echo(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [self] data, _, isComplete, error in
            if let data, !data.isEmpty { connection.send(content: data, completion: .contentProcessed { _ in }) }
            if isComplete || error != nil { connection.cancel() } else { echo(on: connection) }
        }
    }
}

enum TLSExchangeResult: Sendable, Equatable {
    case echoed(Data, serverFingerprint: DeviceFingerprint?)
    case failed
}

enum TLSLoopback {
    static let timeout: DispatchTimeInterval = .seconds(5)

    /// Connects, sends `message` and waits for the echo. Any failure, close or timeout is `.failed`.
    static func exchange(_ message: Data, port: UInt16, parameters: NWParameters) async -> TLSExchangeResult {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return .failed }
        let connection = NWConnection(host: "127.0.0.1", port: nwPort, using: parameters)
        let queue = DispatchQueue(label: "tls-loopback-client")
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<TLSExchangeResult, Never>) in
            let once = OneShot(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: sendAndAwaitEcho(message, on: connection, once: once)
                case .failed, .waiting, .cancelled: once.resume(.failed)
                default: break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) { once.resume(.failed) }
            connection.start(queue: queue)
        }
        connection.cancel()
        return result
    }

    private static func sendAndAwaitEcho(_ message: Data, on connection: NWConnection, once: OneShot<TLSExchangeResult>) {
        let serverFingerprint = TLSParameters.peerFingerprint(of: connection)
        connection.send(content: message, completion: .contentProcessed { error in
            if error != nil { once.resume(.failed) }
        })
        connection.receive(minimumIncompleteLength: message.count, maximumLength: message.count) { data, _, _, error in
            guard error == nil, let data, data == message else { return once.resume(.failed) }
            once.resume(.echoed(data, serverFingerprint: serverFingerprint))
        }
    }
}
