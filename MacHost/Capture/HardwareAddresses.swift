import Darwin
import Foundation
import RemoteCore

/// One network interface as read from the system.
struct NetworkInterfaceInfo: Equatable, Sendable {
    let name: String
    let mac: [UInt8]?
    /// Has an IPv4 address that is not link-local.
    let hasIPv4: Bool
}

/// The Mac's hardware addresses for Wake-on-LAN, reported to the iPhone in the host info.
enum HardwareAddresses {
    static let maxReported = 4

    /// Physical adapters (`en*`) that are up with an IPv4 address and have a real hardware address,
    /// without duplicates. Idle adapters (such as unused Thunderbolt ones) are left out.
    static func wakeCandidates(from interfaces: [NetworkInterfaceInfo]) -> [String] {
        var seen = Set<MACAddress>()
        var result: [String] = []
        for interface in interfaces where interface.name.hasPrefix("en") && interface.hasIPv4 {
            guard let bytes = interface.mac, let mac = MACAddress(bytes: bytes), seen.insert(mac).inserted else { continue }
            result.append(mac.description)
            if result.count == maxReported { break }
        }
        return result
    }

    static func current() -> [String] {
        wakeCandidates(from: readInterfaces())
    }

    private static func readInterfaces() -> [NetworkInterfaceInfo] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }

        var macs: [String: [UInt8]] = [:]
        var withIPv4 = Set<String>()
        var order: [String] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr else { continue }
            let name = String(cString: entry.ifa_name)
            if !order.contains(name) { order.append(name) }
            switch Int32(address.pointee.sa_family) {
            case AF_LINK:
                macs[name] = linkAddress(address)
            case AF_INET:
                if isUsableIPv4(address) { withIPv4.insert(name) }
            default:
                break
            }
        }
        return order.map { NetworkInterfaceInfo(name: $0, mac: macs[$0], hasIPv4: withIPv4.contains($0)) }
    }

    /// A link-local 169.254.x.x address means "no DHCP lease": the adapter is not on any network.
    private static func isUsableIPv4(_ address: UnsafeMutablePointer<sockaddr>) -> Bool {
        address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { inet in
            let value = UInt32(bigEndian: inet.pointee.sin_addr.s_addr)
            return value != 0 && value >> 16 != 0xA9FE
        }
    }

    private static func linkAddress(_ address: UnsafeMutablePointer<sockaddr>) -> [UInt8]? {
        address.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { link in
            guard Int(link.pointee.sdl_alen) == MACAddress.byteCount else { return nil }
            let nameLength = Int(link.pointee.sdl_nlen)
            return withUnsafePointer(to: &link.pointee.sdl_data) { data in
                data.withMemoryRebound(to: UInt8.self, capacity: nameLength + MACAddress.byteCount) { bytes in
                    Array(UnsafeBufferPointer(start: bytes + nameLength, count: MACAddress.byteCount))
                }
            }
        }
    }
}
