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

    @ObservationIgnored private let environment: HostEnvironment
    @ObservationIgnored private let store: PairedDeviceStore
    @ObservationIgnored private let logger = AppLog.logger(category: "host-session")
    @ObservationIgnored private let injector = InputInjector()
    @ObservationIgnored private var identity: DeviceIdentity?
    @ObservationIgnored private var coordinator: PairingCoordinator?
    @ObservationIgnored private var server: StreamServer?
    @ObservationIgnored private var pipeline: StreamingPipeline?
    @ObservationIgnored private var eventLoop: Task<Void, Never>?
    @ObservationIgnored private var pairingExpiry: Task<Void, Never>?
    @ObservationIgnored private var listeningPort: UInt16 = 0
    @ObservationIgnored private var hasWarnedAboutAccessibility = false

    init(environment: HostEnvironment = .live) {
        self.environment = environment
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
            serviceType: environment.serviceType, port: environment.port, limits: environment.limits
        )
        do {
            try server.start()
        } catch {
            state = .failed("Could not start the secure server: \(error.localizedDescription)")
            return
        }
        self.coordinator = coordinator
        self.server = server
        refreshPairedDevices()
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
        cancelPairing()
        injector.releaseAll()
        server?.stop()
        eventLoop?.cancel()
        await stopPipeline()
        server = nil
        coordinator = nil
        eventLoop = nil
        connectedDeviceName = nil
        connectedDeviceFingerprint = nil
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
            await startPipeline()
        case .clientDisconnected:
            injector.releaseAll()
            connectedDeviceName = nil
            connectedDeviceFingerprint = nil
            await stopPipeline()
            if isHosting { state = .listening(port: listeningPort) }
        case .keyframeNeeded:
            pipeline?.forceKeyframe()
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
