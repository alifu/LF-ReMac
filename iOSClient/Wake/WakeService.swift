import Darwin
import Foundation
import RemoteCore

struct WifiInterface: Equatable, Sendable {
    let ip: String
    let netmask: String
}

enum UDPBroadcastError: Error, Equatable {
    case invalidAddress
    case socketFailed(errno: Int32)
    case sendFailed(errno: Int32)
}

/// UDP datagrams over a BSD socket with `SO_BROADCAST`. Network.framework is refused on a free
/// account (EACCES to a subnet broadcast address); a plain socket is allowed (verified on an iPhone 12, Phase 7.4).
enum UDPBroadcast {
    static func send(_ payload: Data, to host: String, port: UInt16) throws(UDPBroadcastError) {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { throw .invalidAddress }

        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { throw .socketFailed(errno: errno) }
        defer { close(descriptor) }
        var enabled: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_BROADCAST, &enabled, socklen_t(MemoryLayout<Int32>.size))

        let sent = payload.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(descriptor, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == payload.count else { throw .sendFailed(errno: errno) }
    }
}

/// The iPhone's own Wi-Fi address and mask (`en0`), used to find the subnet broadcast address.
enum WifiInterfaceReader {
    static func current() -> WifiInterface? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard String(cString: entry.ifa_name) == "en0", let address = entry.ifa_addr, let mask = entry.ifa_netmask,
                  Int32(address.pointee.sa_family) == AF_INET,
                  let ip = dotted(address), let netmask = dotted(mask) else { continue }
            return WifiInterface(ip: ip, netmask: netmask)
        }
        return nil
    }

    private static func dotted(_ address: UnsafeMutablePointer<sockaddr>) -> String? {
        address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { inet in
            var value = inet.pointee.sin_addr
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            return inet_ntop(AF_INET, &value, &buffer, socklen_t(INET_ADDRSTRLEN)).map { String(cString: $0) }
        }
    }
}

/// Wakes a sleeping Mac by broadcasting Wake-on-LAN magic packets on the local network.
/// It cannot work over Tailscale or the internet (no broadcast there) and the Mac must allow
/// "Wake for network access".
struct WakeService: Sendable {
    enum Outcome: Equatable, Sendable {
        case sent(addressCount: Int)
        case noKnownAddress
        case notOnLocalNetwork
        case failed(String)

        var message: String {
            switch self {
            case .sent: "Wake signal sent. The Mac can take a few seconds to wake up."
            case .noKnownAddress: "Connect to this Mac once while it is awake so it can tell this iPhone how to wake it."
            case .notOnLocalNetwork: "Wake works only on the same Wi-Fi network as the Mac."
            case .failed(let reason): "Could not send the wake signal (\(reason))."
            }
        }
    }

    static let port: UInt16 = 9
    /// UDP can be lost, and the Mac's network card only needs to hear one.
    static let copiesPerAddress = 3

    var wifiInterface: @Sendable () -> WifiInterface?
    var transmit: @Sendable (_ packet: Data, _ broadcast: String) throws(UDPBroadcastError) -> Void

    static let live = WakeService(
        wifiInterface: { WifiInterfaceReader.current() },
        transmit: { (packet, broadcast) throws(UDPBroadcastError) in try UDPBroadcast.send(packet, to: broadcast, port: port) }
    )

    func wake(_ host: PairedHost) -> Outcome {
        let addresses = host.wakeAddresses
        guard !addresses.isEmpty else { return .noKnownAddress }
        guard let wifi = wifiInterface(),
              let broadcast = DirectedBroadcast.address(ip: wifi.ip, netmask: wifi.netmask)
        else { return .notOnLocalNetwork }
        do throws(UDPBroadcastError) {
            for mac in addresses {
                let packet = MagicPacket.data(for: mac)
                for _ in 0..<Self.copiesPerAddress { try transmit(packet, broadcast) }
            }
        } catch {
            return .failed(String(describing: error))
        }
        return .sent(addressCount: addresses.count)
    }
}
