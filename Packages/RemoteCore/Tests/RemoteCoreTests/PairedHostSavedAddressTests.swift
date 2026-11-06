import Foundation
import Testing
@testable import RemoteCore

struct PairedHostSavedAddressTests {
    private let pairedAt = Date(timeIntervalSince1970: 1_700_000_000)

    private func host(lastKnown: String? = "10.0.0.2", saved: String? = nil, savedPort: UInt16? = nil) -> PairedHost {
        PairedHost(
            name: "Mac mini",
            fingerprint: Fixtures.fingerprint(7),
            pairedAt: pairedAt,
            lastKnownHost: lastKnown,
            lastKnownPort: lastKnown == nil ? nil : 47800,
            savedHost: saved,
            savedPort: savedPort
        )
    }

    @Test func decodesJSONStoredBeforeSavedAddressesExisted() throws {
        let current = host()
        let encoded = try JSONEncoder().encode(current)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "savedHost")
        object.removeValue(forKey: "savedPort")
        let oldJSON = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(PairedHost.self, from: oldJSON)

        #expect(decoded.savedHost == nil)
        #expect(decoded.savedPort == nil)
        #expect(decoded.lastKnownHost == "10.0.0.2")
        #expect(decoded.fingerprint == current.fingerprint)
    }

    @Test func savedAddressSurvivesARoundTrip() throws {
        let current = host(saved: "mac-mini.tail1234.ts.net", savedPort: 47801)

        let decoded = try JSONDecoder().decode(PairedHost.self, from: JSONEncoder().encode(current))

        #expect(decoded.savedHost == "mac-mini.tail1234.ts.net")
        #expect(decoded.savedPort == 47801)
    }

    @Test func defaultInitializerLeavesSavedAddressEmpty() {
        #expect(host().savedHost == nil)
        #expect(host().savedPort == nil)
    }

    @Test func reachedPreservesTheSavedAddress() {
        let current = host(saved: "100.101.102.103", savedPort: 47800)

        let moved = current.reached(at: "10.0.0.9", port: 47900)

        #expect(moved.lastKnownHost == "10.0.0.9")
        #expect(moved.lastKnownPort == 47900)
        #expect(moved.savedHost == "100.101.102.103")
        #expect(moved.savedPort == 47800)
    }

    @Test func withSavedAddressSetsOnlyTheSavedFields() {
        let current = host(saved: nil)

        let updated = current.withSavedAddress(host: "mac-mini.tail1234.ts.net", port: 47800)

        #expect(updated.savedHost == "mac-mini.tail1234.ts.net")
        #expect(updated.savedPort == 47800)
        #expect(updated.lastKnownHost == "10.0.0.2")
        #expect(updated.fingerprint == current.fingerprint)
        #expect(updated.pairedAt == current.pairedAt)
    }

    @Test func withSavedAddressNilClearsTheSavedAddressOnly() {
        let current = host(saved: "100.101.102.103", savedPort: 47800)

        let cleared = current.withSavedAddress(host: nil, port: nil)

        #expect(cleared.savedHost == nil)
        #expect(cleared.savedPort == nil)
        #expect(cleared.lastKnownHost == "10.0.0.2")
    }
}
