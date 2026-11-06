import Foundation
import Network
import RemoteCore

/// Frame handling per role. Runs on `queue`.
extension StreamServer {
    /// The active, paired session: Phase 2/3 behaviour.
    func handlePaired(_ frame: Frame, from session: PeerConnection) {
        switch frame.type {
        case .keyframeRequest:
            continuation.yield(.keyframeNeeded)
        case .ping:
            // Echo for round-trip latency measurement; goes through the gate to keep its pending count balanced.
            if session.gate.decide(for: frame) == .send { send(frame, on: session) }
        case .input:
            forwardInput(frame)
        case .clientHello:
            handleHello(frame, from: session)
        case .selectDisplay:
            handleSelectDisplay(frame)
        case .audioControl:
            break // Handled in Phase 7.7 (audio capture)
        case .videoConfig, .videoFrame, .hostInfo, .audioConfig, .audioFrame, .pairRequest, .pairResponse:
            break
        }
    }

    /// An unpaired peer during the pairing window. Its decoder only lets `pairRequest` through, and
    /// it gets exactly one attempt: afterwards it is either answered and finished, or cancelled.
    func handlePairing(_ frame: Frame, from peer: PeerConnection, fingerprint: DeviceFingerprint) {
        switch responder.respond(to: frame, from: fingerprint) {
        case .accepted(let device, let response):
            logger.info("Paired a new iPhone")
            peer.finishPairing()
            continuation.yield(.devicePaired(device))
            sendFinal(response, on: peer)
        case .rejected(let rejection):
            // No reason on the wire: the peer only sees the connection close.
            logger.notice("Pairing attempt rejected: \(String(describing: rejection), privacy: .public)")
            continuation.yield(.pairingFailed(rejection))
            peer.cancel()
        }
    }

    func send(_ frame: Frame, on session: PeerConnection) {
        let data = FrameEncoder.encode(frame)
        session.connection.send(content: data, completion: .contentProcessed { [weak self, weak session] error in
            guard let self, let session else { return }
            queue.async {
                session.gate.sendCompleted()
                if let error {
                    self.logger.error("Send failed: \(error.localizedDescription, privacy: .public)")
                    session.cancel()
                }
            }
        })
    }

    /// Sends the pairing reply followed by a FIN, then closes once the peer hangs up or after a
    /// short linger (the iPhone reconnects in pinned mode).
    private func sendFinal(_ frame: Frame, on peer: PeerConnection) {
        peer.setDeadline(after: limits.pairingLinger, on: queue)
        peer.connection.send(
            content: FrameEncoder.encode(frame), contentContext: .finalMessage, isComplete: true,
            completion: .contentProcessed { [weak self, weak peer] error in
                guard let self, let peer, let error else { return }
                queue.async {
                    self.logger.error("Pairing reply failed: \(error.localizedDescription, privacy: .public)")
                    peer.cancel()
                }
            }
        )
    }

    private func handleHello(_ frame: Frame, from session: PeerConnection) {
        do {
            let capabilities = PeerCapabilities(hello: try SessionMessageCoding.clientHello(from: frame))
            session.capabilities = capabilities
            continuation.yield(.clientHello(capabilities))
        } catch {
            logger.error("Dropped invalid hello: \(String(describing: error), privacy: .public)")
            session.cancel()
        }
    }

    private func handleSelectDisplay(_ frame: Frame) {
        do {
            continuation.yield(.displaySelected(try SessionMessageCoding.selectDisplay(from: frame).displayID))
        } catch {
            logger.error("Dropped invalid display selection: \(String(describing: error), privacy: .public)")
        }
    }

    /// Tells the active client about the displays, if (and only if) its hello asked for them.
    func sendHostInfo(_ info: HostInfo) {
        queue.async {
            guard let session = self.active, session.capabilities.canReceive(.hostInfo) else { return }
            do {
                let frame = try SessionMessageCoding.frame(for: info, timestampMicros: 0)
                if session.gate.decide(for: frame) == .send { self.send(frame, on: session) }
            } catch {
                self.logger.error("Could not encode host info: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func forwardInput(_ frame: Frame) {
        do {
            continuation.yield(.input(try InputEventCoding.event(from: frame)))
        } catch {
            logger.error("Dropped invalid input event: \(String(describing: error), privacy: .public)")
        }
    }
}
