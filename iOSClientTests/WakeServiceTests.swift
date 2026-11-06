import Darwin
import Foundation
import RemoteCore
import Testing
@testable import iOSClient

struct WakeServiceTests {
    private let fingerprint = try! DeviceFingerprint(hex: String(repeating: "cd", count: 32))

    private func host(wake: [String]?) -> PairedHost {
        PairedHost(
            name: "Mac mini", fingerprint: fingerprint, pairedAt: Date(timeIntervalSince1970: 0),
            lastKnownHost: nil, lastKnownPort: nil, wakeMACs: wake
        )
    }

    private final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(Data, String)] = []
        func add(_ packet: Data, _ broadcast: String) { lock.withLock { items.append((packet, broadcast)) } }
        var all: [(Data, String)] { lock.withLock { items } }
    }

    private func service(
        wifi: WifiInterface? = WifiInterface(ip: "192.168.88.22", netmask: "255.255.255.0"),
        sent: Sent, failWith error: UDPBroadcastError? = nil
    ) -> WakeService {
        WakeService(wifiInterface: { wifi }, transmit: { (packet, broadcast) throws(UDPBroadcastError) in
            if let error { throw error }
            sent.add(packet, broadcast)
        })
    }

    @Test func sendsMagicPacketsToTheSubnetBroadcast() {
        let sent = Sent()

        let outcome = service(sent: sent).wake(host(wake: ["aa:bb:cc:01:02:03"]))

        #expect(outcome == .sent(addressCount: 1))
        #expect(!sent.all.isEmpty)
        #expect(sent.all.allSatisfy { $0.1 == "192.168.88.255" && $0.0.count == 102 })
    }

    @Test func sendsForEveryReportedAddress() {
        let sent = Sent()

        let outcome = service(sent: sent).wake(host(wake: ["aa:bb:cc:01:02:03", "aa:bb:cc:01:02:04"]))

        #expect(outcome == .sent(addressCount: 2))
        #expect(Set(sent.all.map(\.0)).count == 2)
    }

    @Test func saysSoWhenTheMacNeverReportedAnAddress() {
        let sent = Sent()
        #expect(service(sent: sent).wake(host(wake: nil)) == .noKnownAddress)
        #expect(service(sent: sent).wake(host(wake: [])) == .noKnownAddress)
        #expect(sent.all.isEmpty)
    }

    @Test func saysSoWhenNotOnWiFi() {
        let sent = Sent()

        #expect(service(wifi: nil, sent: sent).wake(host(wake: ["aa:bb:cc:01:02:03"])) == .notOnLocalNetwork)
        #expect(sent.all.isEmpty)
    }

    @Test func reportsASendFailure() {
        let outcome = service(sent: Sent(), failWith: .sendFailed(errno: EACCES)).wake(host(wake: ["aa:bb:cc:01:02:03"]))

        guard case .failed = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
    }

    @Test func everyOutcomeHasAUserMessage() {
        for outcome in [WakeService.Outcome.sent(addressCount: 1), .noKnownAddress, .notOnLocalNetwork, .failed("x")] {
            #expect(!outcome.message.isEmpty)
        }
    }
}

struct UDPBroadcastLoopbackTests {
    @Test func deliversTheDatagramToTheTargetPort() throws {
        let receiver = socket(AF_INET, SOCK_DGRAM, 0)
        defer { close(receiver) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = UInt32(0x7F000001).bigEndian
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(receiver, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        try #require(bound == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(receiver, $0, &length) }
        }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(receiver, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let port = UInt16(bigEndian: address.sin_port)

        try UDPBroadcast.send(Data([1, 2, 3, 4]), to: "127.0.0.1", port: port)

        var buffer = [UInt8](repeating: 0, count: 16)
        let received = recv(receiver, &buffer, buffer.count, 0)
        #expect(received == 4)
        #expect(Array(buffer.prefix(4)) == [1, 2, 3, 4])
    }

    @Test func rejectsAnInvalidAddress() {
        #expect(throws: UDPBroadcastError.invalidAddress) { try UDPBroadcast.send(Data([1]), to: "not an ip", port: 9) }
    }
}
