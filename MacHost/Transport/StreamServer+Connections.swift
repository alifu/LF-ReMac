import Foundation
import Network
import RemoteCore

/// Connection lifecycle: authorization at `.ready`, the receive loop and teardown. Runs on `queue`.
extension StreamServer {
    func handleConnection(state: NWConnection.State, peer: PeerConnection) {
        switch state {
        case .ready:
            authorize(peer)
        case .failed, .cancelled:
            remove(peer)
        default:
            break
        }
    }

    // MARK: Authorization

    private func authorize(_ peer: PeerConnection) {
        guard peer.role == .handshaking else { return }
        let pairing = others.values.filter(\.isPairing)
        let decision = ConnectionAuthorizer.authorize(
            peer: TLSParameters.peerFingerprint(of: peer.connection),
            hostFingerprint: identity.fingerprint,
            isPaired: { store.contains($0) },
            isPairingOpen: coordinator.isOpen,
            pairingConnections: pairing.count,
            maxPairingConnections: limits.maxPairingConnections,
            pairingConnectionsFromAddress: pairing.filter { $0.source == peer.source }.count,
            maxPairingConnectionsPerAddress: limits.maxPairingConnectionsPerAddress
        )
        switch decision {
        case .paired(let fingerprint):
            activate(peer, fingerprint: fingerprint)
        case .pairing(let fingerprint):
            peer.becomePairing(fingerprint)
            // A timeout only drops the connection; it never uses up a pairing attempt.
            peer.setDeadline(after: limits.pairRequestTimeout, on: queue) { [weak self] in
                self?.logger.notice("Unpaired device sent no pairing request in time")
                self?.continuation.yield(.pairingFailed(.timedOut))
            }
            logger.info("Unpaired iPhone connected during the pairing window")
            receive(on: peer)
        case .refused(let refusal):
            logger.notice("Refused connection: \(String(describing: refusal), privacy: .public)")
            peer.cancel()
        }
    }

    /// Makes a paired connection THE session, replacing any previous one.
    private func activate(_ peer: PeerConnection, fingerprint: DeviceFingerprint) {
        others[ObjectIdentifier(peer)] = nil
        if let previous = active { endActiveSession(previous) }
        peer.becomePaired(fingerprint)
        active = peer
        logger.info("Paired iPhone connected")
        continuation.yield(.clientConnected(fingerprint))
        continuation.yield(.keyframeNeeded)
        receive(on: peer)
    }

    func endActiveSession(_ session: PeerConnection) {
        guard active === session else { return }
        active = nil
        session.cancel()
        if let fingerprint = session.fingerprint {
            logger.info("Client disconnected")
            continuation.yield(.clientDisconnected(fingerprint))
        }
    }

    private func remove(_ peer: PeerConnection) {
        peer.clearDeadline()
        if active === peer {
            endActiveSession(peer)
        } else {
            others[ObjectIdentifier(peer)] = nil
        }
    }

    private func isCurrent(_ peer: PeerConnection) -> Bool {
        !peer.isClosed && (active === peer || others[ObjectIdentifier(peer)] != nil)
    }

    // MARK: Receive loop

    func receive(on peer: PeerConnection) {
        peer.connection.receive(minimumIncompleteLength: 1, maximumLength: peer.readBytes) {
            [weak self, weak peer] data, _, isComplete, error in
            guard let self, let peer else { return }
            queue.async { self.handleReceived(data, isComplete: isComplete, error: error, peer: peer) }
        }
    }

    private func handleReceived(_ data: Data?, isComplete: Bool, error: NWError?, peer: PeerConnection) {
        guard isCurrent(peer) else { return }
        if let data, !data.isEmpty, !process(data, from: peer) { return }
        if let error {
            logger.error("Receive failed: \(error.localizedDescription, privacy: .public)")
            peer.cancel()
        } else if isComplete {
            peer.cancel()
        } else if isCurrent(peer) {
            receive(on: peer)
        }
    }

    /// Returns false when the connection was dropped.
    private func process(_ data: Data, from peer: PeerConnection) -> Bool {
        let frames: [Frame]
        do {
            frames = try peer.decode(data)
        } catch {
            logger.error("Protocol error from client: \(String(describing: error), privacy: .public)")
            rejectProtocolViolation(from: peer)
            return false
        }
        for frame in frames {
            guard isCurrent(peer) else { return false }
            route(frame, from: peer)
        }
        return isCurrent(peer)
    }

    private func route(_ frame: Frame, from peer: PeerConnection) {
        switch peer.role {
        case .paired:
            handlePaired(frame, from: peer)
        case .pairing(let fingerprint):
            handlePairing(frame, from: peer, fingerprint: fingerprint)
        case .handshaking, .finished:
            // Nothing is expected after the pairing reply.
            peer.cancel()
        }
    }

    /// Undecodable, oversized or disallowed traffic: dropped without using up a pairing attempt.
    private func rejectProtocolViolation(from peer: PeerConnection) {
        if peer.isPairing {
            continuation.yield(.pairingFailed(.malformedRequest))
        }
        peer.cancel()
    }
}
