import Foundation
import Testing
@testable import MacHost

struct HardwareAddressesTests {
    private func interface(_ name: String, mac: [UInt8]? = [0xAA, 0xBB, 0xCC, 0x00, 0x00, 0x01], hasIPv4: Bool = true) -> NetworkInterfaceInfo {
        NetworkInterfaceInfo(name: name, mac: mac, hasIPv4: hasIPv4)
    }

    @Test func keepsEthernetAndWiFiWithAnAddress() {
        let result = HardwareAddresses.wakeCandidates(from: [
            interface("en0", mac: [1, 2, 3, 4, 5, 6]),
            interface("en1", mac: [1, 2, 3, 4, 5, 7]),
        ])

        #expect(result == ["01:02:03:04:05:06", "01:02:03:04:05:07"])
    }

    @Test func skipsVirtualAndLoopbackInterfaces() {
        let result = HardwareAddresses.wakeCandidates(from: [
            interface("lo0"), interface("awdl0"), interface("llw0"), interface("utun3"), interface("bridge0"),
            interface("en0", mac: [1, 2, 3, 4, 5, 6]),
        ])

        #expect(result == ["01:02:03:04:05:06"])
    }

    @Test func skipsInterfacesWithoutAnIPv4AddressSoIdleAdaptersAreNotReported() {
        let result = HardwareAddresses.wakeCandidates(from: [
            interface("en2", hasIPv4: false),
            interface("en0", mac: [1, 2, 3, 4, 5, 6]),
        ])

        #expect(result == ["01:02:03:04:05:06"])
    }

    @Test func skipsMissingZeroAndWrongLengthAddresses() {
        let result = HardwareAddresses.wakeCandidates(from: [
            interface("en0", mac: nil),
            interface("en1", mac: [0, 0, 0, 0, 0, 0]),
            interface("en2", mac: [1, 2, 3]),
        ])

        #expect(result.isEmpty)
    }

    @Test func removesDuplicatesAndCapsTheCount() {
        let same = [interface("en0", mac: [1, 2, 3, 4, 5, 6]), interface("en1", mac: [1, 2, 3, 4, 5, 6])]
        #expect(HardwareAddresses.wakeCandidates(from: same).count == 1)

        let many = (0..<10).map { interface("en\($0)", mac: [1, 2, 3, 4, 5, UInt8($0 + 1)]) }
        #expect(HardwareAddresses.wakeCandidates(from: many).count == 4)
    }
}
