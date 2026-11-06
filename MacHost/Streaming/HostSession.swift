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
    /// Off by default and after every launch: until pairing exists (Phase 4), anyone on the network
    /// who connects could otherwise control this Mac.
    private(set) var isRemoteControlEnabled = false

    private let logger = AppLog.logger(category: "host-session")
    private var server: StreamServer?
    private var pipeline: StreamingPipeline?
    private var eventLoop: Task<Void, Never>?
    private let injector = InputInjector()
    private var hasWarnedAboutAccessibility = false

    var isHosting: Bool {
        switch state {
        case .listening, .streaming: true
        case .stopped, .failed: false
        }
    }

    func start() {
        guard !isHosting else { return }
        let server = StreamServer(port: StreamServer.defaultPort)
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

    func setRemoteControl(enabled: Bool) {
        isRemoteControlEnabled = enabled
        if enabled {
            if !AccessibilityPermission.isGranted { AccessibilityPermission.requestPrompt() }
        } else {
            injector.releaseAll()
        }
    }

    func stop() async {
        injector.releaseAll()
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
            injector.releaseAll()
            await stopPipeline()
            state = .listening(port: listeningPort)
        case .keyframeNeeded:
            pipeline?.forceKeyframe()
        case .input(let input):
            handleInput(input)
        case .failed(let message):
            await stopPipeline()
            state = .failed(message)
        }
    }

    private func handleInput(_ input: InputEvent) {
        guard isRemoteControlEnabled else { return }
        guard AccessibilityPermission.isGranted else {
            if !hasWarnedAboutAccessibility {
                hasWarnedAboutAccessibility = true
                logger.error("Remote control is on but Accessibility permission is missing")
            }
            return
        }
        injector.inject(input)
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
