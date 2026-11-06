import Foundation
import Network

public enum PairingHandshakeError: Error, Equatable, Sendable {
    /// No TCP/TLS connection could be established (wrong address, Mac not hosting, no network).
    case cannotReach
    /// The Mac's TLS key is not the one the invitation (QR code) names: possible impostor.
    case hostFingerprintMismatch
    /// The Mac closed the connection without a reply: wrong or expired code, or no pairing window open.
    case rejected
    /// The reply's proof does not verify: the peer does not know the secret (possible impostor).
    case invalidHostProof
    /// The reply was not a well-formed pairing response.
    case invalidResponse
    case timedOut
    /// This device's name cannot be sent (see `DeviceName`).
    case invalidDeviceName
}

/// What the client learned from a verified pairing exchange.
public struct PairingHandshakeResult: Equatable, Sendable {
    public let hostName: String
    /// Taken from the TLS handshake, authenticated by the host proof.
    public let hostFingerprint: DeviceFingerprint
    /// Address the connection actually used, if it was an IP/host endpoint.
    public let remoteHost: String?
    public let remotePort: UInt16?

    public init(hostName: String, hostFingerprint: DeviceFingerprint, remoteHost: String?, remotePort: UInt16?) {
        self.hostName = hostName
        self.hostFingerprint = hostFingerprint
        self.remoteHost = remoteHost
        self.remotePort = remotePort
    }
}

/// Client side of pairing over mutual TLS 1.3 (plan, Phase 4):
/// TLS connect with this device's identity -> read the server fingerprint from the handshake ->
/// send `pairRequest` -> receive `pairResponse` (small decoder, timeout) -> verify the host proof
/// with both handshake fingerprints. The caller must persist the host only after this returns.
///
/// With `expectedHostFingerprint` (QR flow) the TLS layer itself refuses any other server key;
/// without it (manual code entry) any server key is tolerated in the handshake because the proofs
/// bind both fingerprints: an impostor without the secret cannot produce a valid host proof.
public enum PairingHandshake {
    public static let defaultTimeout: Duration = .seconds(10)

    public static func run(
        endpoint: NWEndpoint,
        identity: DeviceIdentity,
        secret: PairingSecret,
        expectedHostFingerprint: DeviceFingerprint?,
        deviceName: String,
        timeout: Duration = defaultTimeout
    ) async throws(PairingHandshakeError) -> PairingHandshakeResult {
        guard DeviceName.isValid(deviceName) else { throw .invalidDeviceName }
        let runner = PairingHandshakeRunner(
            identity: identity, secret: secret, expected: expectedHostFingerprint, deviceName: deviceName
        )
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                runner.start(endpoint: endpoint, timeout: timeout) { continuation.resume(returning: $0) }
            }
        } onCancel: {
            runner.abort()
        }
        return try result.get()
    }
}

/// One pairing attempt. All state is confined to `queue`.
private final class PairingHandshakeRunner: @unchecked Sendable {
    typealias Completion = @Sendable (Result<PairingHandshakeResult, PairingHandshakeError>) -> Void

    private let identity: DeviceIdentity
    private let secret: PairingSecret
    private let expected: DeviceFingerprint?
    private let deviceName: String
    private let queue = DispatchQueue(label: "com.alifu.lfremac.pairing-client")
    private let mismatchSeen = MismatchFlag()
    private var connection: NWConnection?
    private var completion: Completion?
    private var serverFingerprint: DeviceFingerprint?
    private var decoder = PairingExchange.responseDecoder()

    init(identity: DeviceIdentity, secret: PairingSecret, expected: DeviceFingerprint?, deviceName: String) {
        self.identity = identity
        self.secret = secret
        self.expected = expected
        self.deviceName = deviceName
    }

    func start(endpoint: NWEndpoint, timeout: Duration, completion: @escaping Completion) {
        queue.async { [self] in
            self.completion = completion
            let parameters: NWParameters
            do {
                parameters = try TLSParameters.client(identity: identity, isPeerAllowed: peerPolicy())
            } catch {
                return finish(.failure(.cannotReach))
            }
            let connection = NWConnection(to: endpoint, using: parameters)
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in self?.handle(state) }
            queue.asyncAfter(deadline: .now() + timeout.timeInterval) { [weak self] in self?.finish(.failure(.timedOut)) }
            connection.start(queue: queue)
        }
    }

    func abort() {
        queue.async { [weak self] in self?.finish(.failure(.timedOut)) }
    }

    // MARK: Private (on `queue`)

    private func peerPolicy() -> TLSParameters.PeerPolicy {
        guard let expected else { return { _ in true } }
        let flag = mismatchSeen
        return { fingerprint in
            let matches = fingerprint == expected
            if !matches { flag.set() }
            return matches
        }
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            sendRequest()
        case .waiting(let error), .failed(let error):
            // Network.framework parks refused handshakes and unreachable hosts in `.waiting`.
            finish(.failure(failureBeforeResponse(error)))
        case .cancelled:
            finish(.failure(.rejected))
        default:
            break
        }
    }

    private func failureBeforeResponse(_ error: NWError) -> PairingHandshakeError {
        if mismatchSeen.isSet { return .hostFingerprintMismatch }
        if serverFingerprint != nil { return .rejected }
        if case .tls = error { return .rejected }
        return .cannotReach
    }

    private func sendRequest() {
        guard let connection, let server = TLSParameters.peerFingerprint(of: connection) else {
            return finish(.failure(.invalidResponse))
        }
        // Defence in depth: the verify block already enforced this in the handshake.
        if let expected, server != expected { return finish(.failure(.hostFingerprintMismatch)) }
        serverFingerprint = server
        let frame: Frame
        do {
            frame = try PairingExchange.requestFrame(
                secret: secret, clientFingerprint: identity.fingerprint, serverFingerprint: server, deviceName: deviceName
            )
        } catch {
            return finish(.failure(.invalidDeviceName))
        }
        connection.send(content: FrameEncoder.encode(frame), completion: .contentProcessed { _ in })
        receive()
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: PairingExchange.maxReadBytes) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            queue.async { self.handleReceived(data, isComplete: isComplete, error: error) }
        }
    }

    private func handleReceived(_ data: Data?, isComplete: Bool, error: NWError?) {
        guard completion != nil else { return }
        if let data, !data.isEmpty {
            let frames: [Frame]
            do {
                frames = try decoder.append(data)
            } catch {
                return finish(.failure(.invalidResponse))
            }
            if let frame = frames.first { return verify(frame) }
        }
        if error != nil || isComplete {
            finish(.failure(.rejected))
        } else {
            receive()
        }
    }

    private func verify(_ frame: Frame) {
        guard let connection, let server = serverFingerprint else { return finish(.failure(.invalidResponse)) }
        do {
            let response = try PairingExchange.verifiedResponse(
                frame, secret: secret, clientFingerprint: identity.fingerprint, serverFingerprint: server
            )
            let remote = RemoteAddress(connection.currentPath?.remoteEndpoint)
            finish(.success(PairingHandshakeResult(
                hostName: response.hostName, hostFingerprint: server, remoteHost: remote.host, remotePort: remote.port
            )))
        } catch .invalidHostProof {
            finish(.failure(.invalidHostProof))
        } catch {
            finish(.failure(.invalidResponse))
        }
    }

    private func finish(_ result: Result<PairingHandshakeResult, PairingHandshakeError>) {
        guard let completion else { return }
        self.completion = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        completion(result)
    }
}
