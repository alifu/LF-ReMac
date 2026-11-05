import Foundation
import Observation
import RemoteCore

/// Owns the server and the capture pipeline. Screen capture only runs while a client is connected.
@MainActor
@Observable
final class HostSession {
    enum State: Equatable {
        case stopped
        case listening(port: UInt16)
        case streaming
        case failed(String)
    }

    private(set) var state: State = .stopped

    private let logger = AppLog.logger(category: "host-session")
    private var server: StreamServer?
    private var pipeline: StreamingPipeline?
    private var eventLoop: Task<Void, Never>?

    var isHosting: Bool {
        switch state {
        case .listening, .streaming: true
        case .stopped, .failed: false
        }
    }

    func start() {
        guard !isHosting else { return }
        let server = StreamServer()
        do {
            try server.start()
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        self.server = server
        eventLoop = Task { [weak self] in
            for await event in server.events {
                await self?.handle(event)
            }
        }
    }

    func stop() async {
        server?.stop()
        eventLoop?.cancel()
        await stopPipeline()
        server = nil
        eventLoop = nil
        state = .stopped
    }

    // MARK: - Events

    private var listeningPort: UInt16 = 0

    private func handle(_ event: StreamServerEvent) async {
        switch event {
        case .ready(let port):
            listeningPort = port
            state = .listening(port: port)
        case .clientConnected:
            await startPipeline()
        case .clientDisconnected:
            await stopPipeline()
            state = .listening(port: listeningPort)
        case .keyframeNeeded:
            pipeline?.forceKeyframe()
        case .failed(let message):
            await stopPipeline()
            state = .failed(message)
        }
    }

    private func startPipeline() async {
        guard let server else { return }
        await stopPipeline()
        let pipeline = StreamingPipeline()
        do {
            try await pipeline.start { event in server.broadcast(event.asFrame) }
            self.pipeline = pipeline
            state = .streaming
        } catch {
            logger.error("Could not start streaming: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
        }
    }

    private func stopPipeline() async {
        guard let pipeline else { return }
        self.pipeline = nil
        await pipeline.stop()
    }
}
