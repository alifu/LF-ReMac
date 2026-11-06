import Foundation
import Network
import RemoteCore
import Testing
@testable import iOSClient

struct LinkCloseClassifierTests {
    private let acceptedLink = LinkHistory(reachedReady: true, receivedFrame: true, secondsAfterReady: 60)
    private let silentLink = LinkHistory(reachedReady: true, receivedFrame: false, secondsAfterReady: 0.2)

    @Test func closeRightAfterReadyWithoutAnyFrameMeansTheMacRefusedUs() {
        #expect(LinkCloseClassifier.message(for: .closedByHost, history: silentLink) == LinkCloseClassifier.notRecognised)
        #expect(LinkCloseClassifier.message(for: .failed("reset", isTLS: false), history: silentLink) == LinkCloseClassifier.notRecognised)
    }

    @Test func tlsAlertAfterReadyIsARefusalEvenLater() {
        let late = LinkHistory(reachedReady: true, receivedFrame: false, secondsAfterReady: 30)

        #expect(LinkCloseClassifier.message(for: .failed("alert", isTLS: true), history: late) == LinkCloseClassifier.notRecognised)
    }

    @Test func wrongHostKeyWins() {
        let history = LinkHistory(reachedReady: false, receivedFrame: false, secondsAfterReady: nil, sawWrongHostKey: true)

        #expect(LinkCloseClassifier.message(for: .unreachable("tls"), history: history) == LinkCloseClassifier.wrongHostKey)
    }

    @Test func ordinaryClosesKeepTheirMessages() {
        #expect(LinkCloseClassifier.message(for: .closedByHost, history: acceptedLink) == "The Mac closed the connection.")
        #expect(LinkCloseClassifier.message(for: .local, history: silentLink) == nil)
        #expect(LinkCloseClassifier.message(for: .unreachable("refused"), history: LinkHistory()) == "Cannot reach the Mac: refused")
    }
}

struct PairedHostTargetTests {
    private static let fingerprint = (try? DeviceFingerprint(bytes: Data(repeating: 1, count: 32)))
        ?? { preconditionFailure("fixture fingerprint") }()

    private func host(name: String = "Mac mini", address: String? = "10.0.0.2", port: UInt16? = 47800) -> PairedHost {
        PairedHost(name: name, fingerprint: Self.fingerprint, pairedAt: Date(), lastKnownHost: address, lastKnownPort: port)
    }

    @Test func prefersTheBonjourServiceWithTheSameName() {
        let service = NWEndpoint.service(name: "Mac mini", type: "_lfremac._tcp", domain: "local.", interface: nil)
        let discovered = [DiscoveredHost(name: "Mac mini", endpoint: service)]

        #expect(PairedHostTarget.endpoint(for: host(), discovered: discovered) == service)
    }

    @Test func fallsBackToTheLastKnownAddress() {
        #expect(PairedHostTarget.endpoint(for: host(), discovered: []) == .hostPort(host: "10.0.0.2", port: 47800))
    }

    @Test func noTargetWithoutServiceOrAddress() {
        #expect(PairedHostTarget.endpoint(for: host(address: nil), discovered: []) == nil)
        #expect(PairedHostTarget.endpoint(for: host(port: nil), discovered: []) == nil)
    }

    @Test func unpairedListExcludesPairedNames() {
        let service = NWEndpoint.service(name: "x", type: "_lfremac._tcp", domain: "local.", interface: nil)
        let discovered = [DiscoveredHost(name: "Mac mini", endpoint: service), DiscoveredHost(name: "Other", endpoint: service)]

        #expect(PairedHostTarget.unpaired(discovered, paired: [host()]).map(\.name) == ["Other"])
    }
}
