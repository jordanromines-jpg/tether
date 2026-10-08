import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Wake-on-LAN: a Mac that's awake sends the "magic packet" to wake another Mac on the same network.
/// Pure helpers plus a small UDP sender, so it can be tested with a local listener.
public enum WakeOnLAN {
    /// "a4:83:e7:12:34:56" (or with dashes) → 6 bytes. Nil for anything else, or an all-zero address.
    public static func parseMAC(_ s: String) -> [UInt8]? {
        let parts = s.split(whereSeparator: { $0 == ":" || $0 == "-" })
        guard parts.count == 6 else { return nil }
        let bytes = parts.compactMap { $0.count == 2 ? UInt8($0, radix: 16) : nil }
        guard bytes.count == 6, bytes.contains(where: { $0 != 0 }) else { return nil }
        return bytes
    }

    /// A made-up address, like macOS's "Private Wi-Fi address": no network card answers to it,
    /// so it can't be used to wake the Mac.
    public static func isRandomized(_ mac: [UInt8]) -> Bool { (mac.first ?? 0) & 0x02 != 0 }

    public static func formatMAC(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined(separator: ":") }

    /// Six 0xFF bytes, then the MAC address 16 times (102 bytes).
    public static func packet(mac: [UInt8]) -> [UInt8] {
        [UInt8](repeating: 0xFF, count: 6) + (0..<16).flatMap { _ in mac }
    }

    /// "192.168.1.0/24" for 192.168.1.20 with mask 255.255.255.0: what two Macs compare to know
    /// they're on the same network.
    public static func network(ip: UInt32, mask: UInt32) -> String {
        "\(dotted(ip & mask))/\(mask.nonzeroBitCount)"
    }

    /// The network's broadcast address (192.168.1.255 for the example above).
    public static func broadcast(ip: UInt32, mask: UInt32) -> String { dotted(ip | ~mask) }

    public static func dotted(_ v: UInt32) -> String {
        "\(v >> 24 & 255).\(v >> 16 & 255).\(v >> 8 & 255).\(v & 255)"
    }

    /// Sends one UDP datagram (broadcast allowed). Returns false if it couldn't be sent.
    @discardableResult
    public static func send(_ bytes: [UInt8], to host: String, port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return false }
        let sent = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return sent == bytes.count
    }
}
