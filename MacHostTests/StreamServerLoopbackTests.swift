import Foundation
import Network
import RemoteCore
import Testing
@testable import MacHost

/// Real TCP over loopback: a raw `NWConnection` plays the iPhone.
struct StreamServerLoopbackTests {
    private static let timeout: Duration = .seconds(5)

    private func startServer() async throws -> (StreamServer, UInt16) {
        let server = StreamServer(serviceType: nil)
        try server.start()
        for await event in server.events {
            if case .ready(let port) = event { return (server, port) }
        }
        throw LoopbackError.serverNeverReady
    }

    private func connect(to port: UInt16) -> LoopbackClient {
        LoopbackClient(port: port)
    }

    @Test func reportsClientConnectionAndRequestsKeyframe() async throws {
        let (server, port) = try await startServer()
        defer { server.stop() }
        let client = connect(to: port)
        defer { client.close() }

        var seen: [StreamServerEvent] = []
        for await event in server.events {
            seen.append(event)
            if seen.contains(.keyframeNeeded) { break }
        }

        #expect(seen.contains(.clientConnected))
        #expect(seen.contains(.keyframeNeeded))
    }

    @Test func deliversConfigKeyframeAndDeltaFramesInOrder() async throws {
        let (server, port) = try await startServer()
        defer { server.stop() }
        let client = connect(to: port)
        defer { client.close() }
        try await Self.waitFor(.clientConnected, on: server)

        let config = Frame(type: .videoConfig, timestampMicros: 0, payload: Data([1]))
        let key = Frame(type: .videoFrame, flags: [.keyframe], timestampMicros: 1, payload: Data([2]))
        let delta = Frame(type: .videoFrame, timestampMicros: 2, payload: Data([3]))
        server.broadcast(delta)  // dropped: client has no keyframe yet
        server.broadcast(config)
        server.broadcast(key)
        server.broadcast(delta)

        let received = try await client.receive(count: 3)
        #expect(received == [config, key, delta])
    }

    @Test func echoesPingWithSamePayload() async throws {
        let (server, port) = try await startServer()
        defer { server.stop() }
        let client = connect(to: port)
        defer { client.close() }
        try await Self.waitFor(.clientConnected, on: server)

        let ping = Frame(type: .ping, timestampMicros: 99, payload: Data([7, 7]))
        client.send(ping)

        let received = try await client.receive(count: 1)
        #expect(received == [ping])
    }

    @Test func keyframeRequestFromClientRaisesKeyframeNeeded() async throws {
        let (server, port) = try await startServer()
        defer { server.stop() }
        let client = connect(to: port)
        defer { client.close() }
        try await Self.waitFor(.keyframeNeeded, on: server)  // the automatic one on connect

        client.send(Frame(type: .keyframeRequest, timestampMicros: 0, payload: Data()))

        try await Self.waitFor(.keyframeNeeded, on: server)
    }

    @Test func reportsDisconnectWhenClientCloses() async throws {
        let (server, port) = try await startServer()
        defer { server.stop() }
        let client = connect(to: port)
        try await Self.waitFor(.clientConnected, on: server)

        client.close()

        try await Self.waitFor(.clientDisconnected, on: server)
    }

    private static func waitFor(_ target: StreamServerEvent, on server: StreamServer) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await event in server.events where event == target { return }
                throw LoopbackError.eventNeverArrived
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw LoopbackError.timedOut
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }
}

private enum LoopbackError: Error {
    case serverNeverReady
    case eventNeverArrived
    case timedOut
}

/// Minimal client speaking the frame protocol over a real socket.
private final class LoopbackClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "loopback.client")
    private let box = FrameBox()

    init(port: UInt16) {
        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        connection = NWConnection(to: endpoint, using: .tcp)
        connection.start(queue: queue)
        pump()
    }

    func send(_ frame: Frame) {
        connection.send(content: FrameEncoder.encode(frame), completion: .contentProcessed { _ in })
    }

    func receive(count: Int) async throws -> [Frame] {
        for _ in 0..<500 {
            let frames = box.frames
            if frames.count >= count { return Array(frames.prefix(count)) }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw LoopbackError.timedOut
    }

    func close() {
        connection.cancel()
    }

    private func pump() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data { box.append(data) }
            if error == nil, !done { pump() }
        }
    }
}

private final class FrameBox: @unchecked Sendable {
    private let lock = NSLock()
    private var decoder = FrameDecoder()
    private var stored: [Frame] = []

    var frames: [Frame] {
        lock.withLock { stored }
    }

    func append(_ data: Data) {
        lock.withLock {
            if let decoded = try? decoder.append(data) { stored += decoded }
        }
    }
}
