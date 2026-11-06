import Foundation
import Network
import RemoteCore
import Security
import Testing
@testable import iOSClient

private let fingerprint = (try? DeviceFingerprint(bytes: Data(repeating: 1, count: 32)))
    ?? { preconditionFailure("fixture fingerprint") }()

private func pairedHost(
    address: String? = "10.0.0.2",
    port: UInt16? = 47800,
    saved: String? = nil,
    savedPort: UInt16? = nil
) -> PairedHost {
    PairedHost(
        name: "Mac mini", fingerprint: fingerprint, pairedAt: Date(),
        lastKnownHost: address, lastKnownPort: port, savedHost: saved, savedPort: savedPort
    )
}

private func service(_ interface: String) -> NWEndpoint {
    .service(name: "Mac mini", type: "_lfremac._tcp", domain: "local.\(interface)", interface: nil)
}

struct PairedHostCandidatesTests {
    @Test func everyServiceWithTheNameThenTheLastKnownAddress() {
        let discovered = [
            DiscoveredHost(name: "Mac mini", endpoint: service("b")),
            DiscoveredHost(name: "Other", endpoint: service("x")),
            DiscoveredHost(name: "Mac mini", endpoint: service("a"))
        ]

        let candidates = PairedHostTarget.candidates(for: pairedHost(), discovered: discovered)

        #expect(candidates == [service("a"), service("b"), .hostPort(host: "10.0.0.2", port: 47800)])
    }

    @Test func preferredEndpointComesFirstAndIsNotRepeated() {
        let lastKnown = NWEndpoint.hostPort(host: "10.0.0.2", port: 47800)

        #expect(PairedHostTarget.candidates(preferring: service("a"), for: pairedHost()) == [service("a"), lastKnown])
        #expect(PairedHostTarget.candidates(preferring: lastKnown, for: pairedHost()) == [lastKnown])
        #expect(PairedHostTarget.candidates(for: pairedHost(address: nil), discovered: []).isEmpty)
    }

    @Test func servicesThenSavedAddressThenLastKnownAddress() {
        let saved = NWEndpoint.hostPort(host: "mac-mini.tail1234.ts.net", port: 47801)
        let discovered = [DiscoveredHost(name: "Mac mini", endpoint: service("a"))]
        let host = pairedHost(saved: "mac-mini.tail1234.ts.net", savedPort: 47801)

        #expect(PairedHostTarget.candidates(for: host, discovered: discovered) == [service("a"), saved, .hostPort(host: "10.0.0.2", port: 47800)])
    }

    @Test func savedAddressIsTheOnlyCandidateWhenBonjourFindsNothing() {
        let saved = NWEndpoint.hostPort(host: "100.101.102.103", port: 47800)
        let host = pairedHost(address: nil, port: nil, saved: "100.101.102.103", savedPort: 47800)

        #expect(PairedHostTarget.candidates(for: host, discovered: []) == [saved])
        #expect(PairedHostTarget.endpoint(for: host, discovered: []) == saved)
    }

    @Test func savedAddressIsNotRepeatedWhenItMatchesTheLastKnownAddress() {
        let host = pairedHost(saved: "10.0.0.2", savedPort: 47800)

        #expect(PairedHostTarget.candidates(for: host, discovered: []) == [.hostPort(host: "10.0.0.2", port: 47800)])
    }

    @Test func preferredThenSavedThenLastKnown() {
        let saved = NWEndpoint.hostPort(host: "100.101.102.103", port: 47800)
        let lastKnown = NWEndpoint.hostPort(host: "10.0.0.2", port: 47800)
        let host = pairedHost(saved: "100.101.102.103", savedPort: 47800)

        #expect(PairedHostTarget.candidates(preferring: service("a"), for: host) == [service("a"), saved, lastKnown])
    }
}

struct ConnectionAttemptsTests {
    private let wrongKey = LinkCloseSummary(
        message: LinkCloseClassifier.wrongHostKey, canTryAnotherAddress: true, sawWrongHostKey: true
    )
    private let unreachable = LinkCloseSummary(
        message: "Cannot reach the Mac: refused", canTryAnotherAddress: true, sawWrongHostKey: false
    )

    @Test func aSpooferAnsweringFirstDoesNotStopTheRealMac() {
        let (first, attempts) = ConnectionAttempts(candidates: [service("spoof"), service("real")]).start()

        let (second, _) = attempts.next(after: wrongKey)

        #expect(first == .dial(service("spoof")))
        #expect(second == .dial(service("real")))
    }

    @Test func whenEveryCandidateFailsAnEarlierWrongKeyIsReported() {
        let (_, attempts) = ConnectionAttempts(candidates: [service("spoof"), service("offline")]).start()
        let (_, afterSpoof) = attempts.next(after: wrongKey)

        let (final, _) = afterSpoof.next(after: unreachable)

        #expect(final == .giveUp(message: LinkCloseClassifier.wrongHostKey))
    }

    @Test func aRefusalByTheRealMacKeepsItsMessage() {
        let refused = LinkCloseSummary(message: LinkCloseClassifier.notRecognised, canTryAnotherAddress: true, sawWrongHostKey: false)
        let (_, attempts) = ConnectionAttempts(candidates: [service("spoof"), service("real")]).start()
        let (_, afterSpoof) = attempts.next(after: wrongKey)

        #expect(afterSpoof.next(after: refused).0 == .giveUp(message: LinkCloseClassifier.notRecognised))
    }

    @Test func userDisconnectOrAnAcceptedSessionNeverMovesOn() {
        let local = LinkCloseSummary(message: nil, canTryAnotherAddress: false, sawWrongHostKey: false)
        let (_, attempts) = ConnectionAttempts(candidates: [service("a"), service("b")]).start()

        #expect(attempts.next(after: local).0 == .giveUp(message: nil))
    }

    @Test func noCandidatesGivesUpAtOnce() {
        #expect(ConnectionAttempts(candidates: []).start().0 == .giveUp(message: ConnectionAttempts.noAddress))
    }

    @Test func mismatchMessageSaysTheMacWasNotReachedAndNeverAsksToPairAgain() {
        #expect(LinkCloseClassifier.wrongHostKey.contains("was not reached"))
        #expect(!LinkCloseClassifier.wrongHostKey.localizedCaseInsensitiveContains("pair again"))
    }
}

struct PairedHostsIssueTests {
    @Test func damagedListIsReportedAndCanBeReset() throws {
        let keyStore = InMemoryKeyStore([PhoneCredentials.pairedHostsKey: Data("garbage".utf8)])
        let credentials = PhoneCredentials(namespace: "com.alifu.lfremac.tests.unused", keyStore: keyStore, deviceName: "Phone")

        let mac = pairedHost()

        #expect(credentials.pairedHostsIssue?.contains("damaged") == true)
        #expect(throws: PeerStoreError.corrupted) { try credentials.hostStore.add(mac) }

        try credentials.resetPairedHosts()

        #expect(credentials.pairedHostsIssue == nil)
        try credentials.hostStore.add(mac)
        #expect(credentials.hostStore.all() == [mac])
    }
}

/// On iOS the attribute is enforced: nothing created here may migrate through backups.
@Suite(.serialized)
struct KeychainAccessibilityTests {
    private static let thisDeviceOnly = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String

    @Test func storedBlobsAreThisDeviceOnly() throws {
        let service = "com.alifu.lfremac.tests.\(UUID().uuidString)"
        let store = KeychainKeyStore(service: service)
        defer { try? store.removeData(forKey: "blob") }
        try store.set(Data([1]), forKey: "blob")

        let attributes = try #require(Self.attributes([
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "blob"
        ]))

        #expect(attributes[kSecAttrAccessible as String] as? String == Self.thisDeviceOnly)
    }

    @Test func identityKeyAndCertificateAreThisDeviceOnly() throws {
        let namespace = "com.alifu.lfremac.tests.\(UUID().uuidString)"
        defer { try? DeviceIdentity.delete(namespace: namespace) }
        _ = try DeviceIdentity.loadOrCreate(deviceName: "Sim Phone", namespace: namespace)

        let key = try #require(Self.attributes([
            kSecClass: kSecClassKey, kSecAttrApplicationTag: Data("\(namespace).identity-key".utf8)
        ]))
        let certificate = try #require(Self.attributes([
            kSecClass: kSecClassCertificate, kSecAttrLabel: "\(namespace).identity"
        ]))

        #expect(key[kSecAttrAccessible as String] as? String == Self.thisDeviceOnly)
        #expect(certificate[kSecAttrAccessible as String] as? String == Self.thisDeviceOnly)
    }

    private static func attributes(_ query: [CFString: Any]) -> [String: Any]? {
        var full = query
        full[kSecReturnAttributes] = true
        full[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(full as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? [String: Any]
    }
}
