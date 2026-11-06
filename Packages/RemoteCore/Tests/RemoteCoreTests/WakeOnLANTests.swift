import Foundation
import Testing
@testable import RemoteCore

struct MACAddressTests {
    @Test func parsesColonAndDashFormsCaseInsensitively() {
        let expected = MACAddress(bytes: [0xAA, 0xBB, 0xCC, 0x01, 0x02, 0x03])

        #expect(MACAddress("aa:bb:cc:01:02:03") == expected)
        #expect(MACAddress("AA-BB-CC-01-02-03") == expected)
    }

    @Test(arguments: ["", "aa:bb:cc:01:02", "aa:bb:cc:01:02:03:04", "gg:bb:cc:01:02:03", "aabbcc010203", "aa:bb:cc:01:02:0", "aa:bb:cc-01:02:03"])
    func rejectsMalformedAddresses(text: String) {
        #expect(MACAddress(text) == nil)
    }

    @Test func rejectsAllZeroAndBroadcastAddresses() {
        #expect(MACAddress("00:00:00:00:00:00") == nil)
        #expect(MACAddress("ff:ff:ff:ff:ff:ff") == nil)
    }

    @Test func printsLowercaseColonForm() {
        #expect(MACAddress("AA-BB-CC-01-02-03")?.description == "aa:bb:cc:01:02:03")
    }

    @Test func rejectsWrongByteCount() {
        #expect(MACAddress(bytes: [1, 2, 3]) == nil)
    }
}

struct MagicPacketTests {
    @Test func isSixFFThenSixteenCopiesOfTheAddress() throws {
        let mac = try #require(MACAddress("aa:bb:cc:01:02:03"))

        let packet = MagicPacket.data(for: mac)

        #expect(packet.count == 102)
        #expect(Array(packet.prefix(6)) == [UInt8](repeating: 0xFF, count: 6))
        for copy in 0..<16 {
            let start = 6 + copy * 6
            #expect(Array(packet[start..<start + 6]) == mac.bytes)
        }
    }
}

struct DirectedBroadcastTests {
    @Test func computesTheSubnetBroadcast() {
        #expect(DirectedBroadcast.address(ip: "192.168.88.22", netmask: "255.255.255.0") == "192.168.88.255")
        #expect(DirectedBroadcast.address(ip: "10.1.2.3", netmask: "255.255.0.0") == "10.1.255.255")
        #expect(DirectedBroadcast.address(ip: "172.16.5.9", netmask: "255.255.252.0") == "172.16.7.255")
    }

    @Test func rejectsBadInput() {
        #expect(DirectedBroadcast.address(ip: "nope", netmask: "255.255.255.0") == nil)
        #expect(DirectedBroadcast.address(ip: "192.168.1.5", netmask: "255.0.255.0") == nil)  // not contiguous
        #expect(DirectedBroadcast.address(ip: "192.168.1.5", netmask: "256.0.0.0") == nil)
    }

    @Test func hostRoutesHaveNoBroadcast() {
        #expect(DirectedBroadcast.address(ip: "192.168.1.5", netmask: "255.255.255.255") == nil)
        #expect(DirectedBroadcast.address(ip: "192.168.1.5", netmask: "0.0.0.0") == nil)
    }
}

struct PairedHostWakeTests {
    private func host(wake: [String]? = nil) throws -> PairedHost {
        PairedHost(
            name: "Mac mini", fingerprint: try DeviceFingerprint(hex: String(repeating: "ab", count: 32)),
            pairedAt: Date(timeIntervalSince1970: 1_700_000_000), lastKnownHost: "10.0.0.2", lastKnownPort: 47800,
            savedHost: "mac.ts.net", savedPort: 47800, wakeMACs: wake
        )
    }

    @Test func decodesJSONStoredBeforeWakeAddressesExisted() throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(host())) as? [String: Any])
        object.removeValue(forKey: "wakeMACs")

        let decoded = try JSONDecoder().decode(PairedHost.self, from: JSONSerialization.data(withJSONObject: object))

        #expect(decoded.wakeAddresses.isEmpty)
    }

    @Test func keepsWakeAddressesWhenTheAddressChanges() throws {
        let original = try host(wake: ["aa:bb:cc:01:02:03"])

        #expect(original.reached(at: "10.0.0.9", port: 47800).wakeAddresses == original.wakeAddresses)
        #expect(original.withSavedAddress(host: nil, port: nil).wakeAddresses == original.wakeAddresses)
    }

    @Test func withWakeMACsKeepsEverythingElseAndSkipsInvalidAddresses() throws {
        let updated = try host().withWakeMACs(["AA-BB-CC-01-02-03", "junk", "aa:bb:cc:01:02:03"])

        #expect(updated.wakeAddresses.map(\.description) == ["aa:bb:cc:01:02:03"])
        #expect(updated.savedHost == "mac.ts.net")
        #expect(updated.lastKnownHost == "10.0.0.2")
    }
}
