import CoreGraphics
import Foundation
import Observation
import RemoteCore

/// Owns identity, paired-device store, pairing window, server and capture pipeline.
/// Screen capture only runs while a paired iPhone is connected.
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
    /// Off by default and after every launch (defence in depth on top of pairing).
    private(set) var isRemoteControlEnabled = false
    private(set) var pairingState: PairingState = .idle
    /// Latest non-fatal pairing problem while the window stays open (e.g. one wrong code).
    private(set) var pairingNotice: String?
    private(set) var pairedDevices: [PairedDevice] = []
    /// Why the paired-iPhones list could not be read (nil when it is fine). While the list is
    /// damaged nothing can be paired; offer `resetPairedDevices()` after the user confirms.
    private(set) var pairedDevicesIssue: String?
    /// Name of the paired iPhone currently streaming, if any.
    private(set) var connectedDeviceName: String?
    /// Key of the connected iPhone; identifies it even if two devices share a name.
    private(set) var connectedDeviceFingerprint: DeviceFingerprint?
    /// Keep the Mac from idle-sleeping while hosting (default on, remembered).
    private(set) var keepsMacAwake: Bool
    /// Accept connections arriving over Tailscale (default off, remembered). LAN is always allowed.
    private(set) var allowsTailscale: Bool

    @ObservationIgnored private let environment: HostEnvironment
    @ObservationIgnored private let store: PairedDeviceStore
    @ObservationIgnored private let logger = AppLog.logger(category: "host-session")
    @ObservationIgnored private let injector = InputInjector()
    @ObservationIgnored private let power: PowerManager
    @ObservationIgnored private var identity: DeviceIdentity?
    @ObservationIgnored private var coordinator: PairingCoordinator?
    @ObservationIgnored private var server: StreamServer?
    @ObservationIgnored private var pipeline: StreamingPipeline?
    @ObservationIgnored private var eventLoop: Task<Void, Never>?
    @ObservationIgnored private var pairingExpiry: Task<Void, Never>?
    @ObservationIgnored private var listeningPort: UInt16 = 0
    @ObservationIgnored private var hasWarnedAboutAccessibility = false
    @ObservationIgnored private var peerCapabilities = PeerCapabilities.legacy
    /// The iPhone turned audio on. Off at every connect; the iPhone sends its remembered choice after the hello.
    @ObservationIgnored private var isAudioRequested = false
    /// Changes whenever an iPhone connects or leaves; a pipeline that finishes starting for an older one is thrown away.
    @ObservationIgnored private var sessionGeneration = 0
    /// Starting a pipeline suspends; only one start may run at a time, and requests made meanwhile are merged (last wins).
    @ObservationIgnored private var isStartingPipeline = false
    @ObservationIgnored private var needsAnotherStart = false
    /// UUID the connected iPhone asked for (or had last time); the display actually streamed may differ after fallback.
    @ObservationIgnored private var requestedDisplayUUID: String?
    @ObservationIgnored private var streamedDisplay: DisplayDescriptor?
    @ObservationIgnored private lazy var displayWatcher = DisplayWatcher { [weak self] in
        Task { await self?.displaysChanged() }
    }

    init(environment: HostEnvironment = .live) {
        self.environment = environment
        self.power = PowerManager(acquire: environment.acquirePowerAssertion)
        self.keepsMacAwake = environment.settings.bool(forKey: HostEnvironment.keepAwakeKey) ?? true
        self.allowsTailscale = environment.settings.bool(forKey: HostEnvironment.allowTailscaleKey) ?? false
        self.store = PairedDeviceStore(keyStore: environment.keyStore, key: HostEnvironment.pairedDevicesKey)
    }

    var isHosting: Bool {
        switch state {
        case .listening, .streaming: true
        case .stopped, .failed: false
        }
    }

    func start() {
        guard !isHosting, let identity = loadIdentity() else { return }
        let coordinator = PairingCoordinator(
            hostFingerprint: identity.fingerprint,
            invitationHost: environment.invitationHost() ?? "",
            clock: environment.clock
        )
        let server = StreamServer(
            identity: identity, store: store, coordinator: coordinator, hostName: environment.displayName(),
            serviceType: environment.serviceType, port: environment.port, limits: environment.limits,
            networkPolicy: NetworkPolicy(allowsTailscale: allowsTailscale)
        )
        do {
            try server.start()
        } catch {
            state = .failed("Could not start the secure server: \(error.localizedDescription)")
            return
        }
        self.coordinator = coordinator
        self.server = server
        power.setKeepAwake(keepsMacAwake)
        refreshPairedDevices()
        eventLoop = Task { [weak self] in
            for await event in server.events {
                await self?.handle(event)
            }
        }
    }

    func setKeepsMacAwake(_ enabled: Bool) {
        keepsMacAwake = enabled
        environment.settings.set(enabled, forKey: HostEnvironment.keepAwakeKey)
        if isHosting { power.setKeepAwake(enabled) }
    }

    func setAllowsTailscale(_ enabled: Bool) {
        allowsTailscale = enabled
        environment.settings.set(enabled, forKey: HostEnvironment.allowTailscaleKey)
        server?.setNetworkPolicy(NetworkPolicy(allowsTailscale: enabled))
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
        cancelPairing()
        injector.releaseAll()
        server?.stop()
        eventLoop?.cancel()
        displayWatcher.stop()
        await stopPipeline()
        server = nil
        coordinator = nil
        eventLoop = nil
        connectedDeviceName = nil
        connectedDeviceFingerprint = nil
        power.setKeepAwake(false)
        state = .stopped
    }

    // MARK: - Pairing

    /// Opens the pairing window (2 minutes, one use, 3 attempts). Nil unless hosting.
    @discardableResult
    func startPairing() -> PairingInvitation? {
        guard isHosting, let coordinator, listeningPort > 0 else { return nil }
        let invitation: PairingInvitation
        do {
            invitation = try coordinator.start(port: listeningPort)
        } catch {
            pairingState = .failed("This Mac has no local network name to put in the QR code.")
            return nil
        }
        let expiresAt = coordinator.expiresAt ?? environment.clock()
        pairingNotice = nil
        pairingState = .open(invitation, expiresAt: expiresAt)
        scheduleExpiry(at: expiresAt)
        return invitation
    }

    func cancelPairing() {
        closePairingWindow()
        pairingNotice = nil
        pairingState = .idle
    }

    /// Forgets `device` and drops its connection at once. The connection is dropped even if
    /// removing it from the Keychain fails; the error is rethrown for the UI.
    func revoke(_ device: PairedDevice) throws(PeerStoreError) {
        defer {
            server?.disconnect(deviceWith: device.fingerprint)
            refreshPairedDevices()
        }
        try store.remove(device.fingerprint)
    }

    func refreshPairedDevices() {
        let snapshot = store.load()
        pairedDevices = snapshot.peers.sorted { $0.pairedAt < $1.pairedAt }
        pairedDevicesIssue = snapshot.issue.map(Self.message(for:))
    }

    /// Deletes a damaged paired-iPhones list so pairing works again. Call only after the user
    /// agreed; does nothing when the list is fine.
    func resetPairedDevices() throws(PeerStoreError) {
        defer { refreshPairedDevices() }
        try store.resetCorruptedStore()
    }

    private static func message(for issue: PeerStoreError) -> String {
        switch issue {
        case .corrupted:
            "The list of paired iPhones is damaged. Reset it, then pair your iPhones again."
        case .keyStore:
            "The list of paired iPhones could not be read from the Keychain."
        case .encodingFailed, .tooManyPeers:
            "The list of paired iPhones could not be read."
        }
    }

    private func scheduleExpiry(at expiresAt: Date) {
        pairingExpiry?.cancel()
        let delay = max(0, expiresAt.timeIntervalSince(environment.clock()))
        pairingExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.pairingWindowExpired()
        }
    }

    private func pairingWindowExpired() {
        guard case .open = pairingState, coordinator?.isOpen != true else { return }
        closePairingWindow()
        pairingState = .failed(PairingRejection.attempt(.expired).userMessage)
    }

    private func closePairingWindow() {
        pairingExpiry?.cancel()
        pairingExpiry = nil
        coordinator?.cancel()
        server?.closePairingConnections()
    }

    private func handlePairingFailure(_ rejection: PairingRejection) {
        guard case .open = pairingState else { return }
        if coordinator?.isOpen == true {
            pairingNotice = rejection.userMessage
        } else {
            closePairingWindow()
            pairingState = .failed(rejection.userMessage)
        }
    }

    // MARK: - Events

    private func handle(_ event: StreamServerEvent) async {
        switch event {
        case .ready(let port):
            listeningPort = port
            state = .listening(port: port)
        case .clientConnected(let fingerprint):
            connectedDeviceName = store.peer(with: fingerprint)?.name
            connectedDeviceFingerprint = fingerprint
            peerCapabilities = .legacy
            isAudioRequested = false
            sessionGeneration += 1
            requestedDisplayUUID = environment.settings.string(forKey: HostEnvironment.selectedDisplayKey(for: fingerprint))
            displayWatcher.start()
            await startPipeline()
        case .clientHello(let capabilities):
            peerCapabilities = capabilities
            sendHostInfo()
        case .audioRequested(let enabled):
            guard enabled != isAudioRequested else { break }  // repeats change nothing
            isAudioRequested = enabled
            if let pipeline, await !pipeline.setAudio(enabled: enabled), enabled { isAudioRequested = false }
        case .displaySelected(let uuid):
            await selectDisplay(uuid)
        case .clientDisconnected:
            displayWatcher.stop()
            peerCapabilities = .legacy
            isAudioRequested = false
            sessionGeneration += 1
            injector.releaseAll()
            connectedDeviceName = nil
            connectedDeviceFingerprint = nil
            await stopPipeline()
            if isHosting { state = .listening(port: listeningPort) }
        case .keyframeNeeded:
            pipeline?.forceKeyframe()
        case .congestion:
            pipeline?.reportCongestion()
        case .input(let input):
            handleInput(input)
        case .devicePaired(let device):
            closePairingWindow()
            pairingNotice = nil
            pairingState = .paired(deviceName: device.name)
            refreshPairedDevices()
        case .pairingFailed(let rejection):
            handlePairingFailure(rejection)
            if rejection == .couldNotSave { refreshPairedDevices() }
        case .failed(let message):
            await stopPipeline()
            state = .failed(message)
        }
    }

    // MARK: - Displays

    private func sendHostInfo() {
        guard peerCapabilities.canReceive(.hostInfo) else { return }
        server?.sendHostInfo(DisplayCatalog.hostInfo(
            displays: environment.displays(), selectedUUID: requestedDisplayUUID, wakeMACs: environment.wakeMACs()
        ))
    }

    /// The iPhone picked a display. Unknown UUIDs (a display that just went away) are ignored.
    private func selectDisplay(_ uuid: String) async {
        let displays = environment.displays()
        guard displays.contains(where: { $0.uuid == uuid }), hasClient else { return }
        requestedDisplayUUID = uuid
        if let fingerprint = connectedDeviceFingerprint {
            environment.settings.set(uuid, forKey: HostEnvironment.selectedDisplayKey(for: fingerprint))
        }
        await restartPipelineIfDisplayChanged(in: displays)
        sendHostInfo()
    }

    /// A display was added, removed or resized: fall back if the streamed one is gone, then refresh the iPhone.
    private func displaysChanged() async {
        guard hasClient else { return }
        await restartPipelineIfDisplayChanged(in: environment.displays())
        sendHostInfo()
    }

    private func restartPipelineIfDisplayChanged(in displays: [DisplayDescriptor]) async {
        let target = DisplayCatalog.resolve(requestedDisplayUUID, in: displays)
        guard DisplayCatalog.needsRestart(from: streamedDisplay, to: target) else { return }
        await startPipeline()
    }

    private func handleInput(_ input: InputEvent) {
        // The server only forwards input from the active paired session; check again here.
        guard isRemoteControlEnabled, connectedDeviceName != nil, pipeline != nil else { return }
        guard AccessibilityPermission.isGranted else {
            if !hasWarnedAboutAccessibility {
                hasWarnedAboutAccessibility = true
                logger.error("Remote control is on but Accessibility permission is missing")
            }
            return
        }
        injector.inject(input)
    }

    private func loadIdentity() -> DeviceIdentity? {
        if let identity { return identity }
        do {
            let identity = try environment.loadIdentity(environment.displayName())
            self.identity = identity
            return identity
        } catch {
            logger.error("Loading the device identity failed: \(String(describing: error), privacy: .public)")
            state = .failed("Could not load this Mac's security identity from the Keychain.")
            return nil
        }
    }

    private var hasClient: Bool { connectedDeviceFingerprint != nil }

    private func startPipeline() async {
        if isStartingPipeline {
            needsAnotherStart = true
            return
        }
        isStartingPipeline = true
        defer { isStartingPipeline = false }
        repeat {
            needsAnotherStart = false
            await startPipelineOnce()
        } while needsAnotherStart && hasClient && DisplayCatalog.needsRestart(
            from: streamedDisplay, to: DisplayCatalog.resolve(requestedDisplayUUID, in: environment.displays())
        )
    }

    private func startPipelineOnce() async {
        guard let server, hasClient else { return }
        await stopPipeline()
        let generation = sessionGeneration
        let wanted = DisplayCatalog.resolve(requestedDisplayUUID, in: environment.displays())?.displayID
        let pipeline = StreamingPipeline()
        do {
            do {
                try await launch(pipeline, on: wanted, server: server)
            } catch where wanted != nil {
                // The chosen display vanished while switching: show the main display instead of nothing.
                logger.notice("Display \(wanted ?? 0) unavailable, using the main display")
                try await launch(pipeline, on: nil, server: server)
            }
        } catch {
            logger.error("Could not start streaming: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
            return
        }
        guard generation == sessionGeneration, hasClient else {
            await pipeline.stop()  // the iPhone left (or another one came) while this was starting
            return
        }
        let used = pipeline.displayID
        self.pipeline = pipeline
        streamedDisplay = environment.displays().first { $0.displayID == used }
        injector.setDisplay(used)
        state = .streaming
        if isAudioRequested, await !pipeline.setAudio(enabled: true) { isAudioRequested = false }
    }

    private func launch(_ pipeline: StreamingPipeline, on displayID: CGDirectDisplayID?, server: StreamServer) async throws {
        try await pipeline.start(
            displayID: displayID,
            audioSink: { server.broadcast($0) },
            sink: { server.broadcast($0.asFrame) }
        )
    }

    private func stopPipeline() async {
        guard let pipeline else { return }
        self.pipeline = nil
        streamedDisplay = nil
        await pipeline.stop()
    }
}

#if DEBUG
extension HostSession {
    /// Screenshot mode only: shows a hosting, connected, mid-pairing Mac without a server or any capture.
    func applyDemoState(connected: PairedDevice, invitation: PairingInvitation) {
        state = .streaming
        connectedDeviceName = connected.name
        connectedDeviceFingerprint = connected.fingerprint
        pairingState = .open(invitation, expiresAt: Date().addingTimeInterval(105))
        refreshPairedDevices()
    }
}
#endif
