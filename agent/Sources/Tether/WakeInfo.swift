import Foundation
import TetherCore

/// This Mac's wired or Wi-Fi network: its hardware (MAC) address, so another Mac can wake it, and its
/// network, so the page knows which Mac can do the waking. Only Ethernet/Wi-Fi (`en*`) with IPv4.
enum WakeInfo {
    struct Interface { let name: String; let mac: String; let ip: UInt32; let mask: UInt32; let randomized: Bool }

    static func interfaces() -> [Interface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var macs: [String: [UInt8]] = [:], v4: [String: (UInt32, UInt32)] = [:]
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en"), let sa = ifa.ifa_addr else { continue }
            if sa.pointee.sa_family == UInt8(AF_LINK) {
                sa.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { dl in
                    guard dl.pointee.sdl_alen == 6 else { return }
                    let bytes = withUnsafeBytes(of: dl.pointee.sdl_data) { raw in
                        Array(raw[Int(dl.pointee.sdl_nlen)..<Int(dl.pointee.sdl_nlen) + 6])
                    }
                    macs[name] = bytes
                }
            } else if sa.pointee.sa_family == UInt8(AF_INET), let nm = ifa.ifa_netmask {
                let ip = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
                let mask = nm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
                if ip >> 16 != 0xA9FE { v4[name] = (ip, mask) }   // skip 169.254.x.x (no network)
            }
        }
        // Real hardware addresses first (a randomized Wi-Fi address can't be woken), then en0, en1…
        return v4.keys.sorted().compactMap { name -> Interface? in
            guard let mac = macs[name], let (ip, mask) = v4[name] else { return nil }
            return Interface(name: name, mac: WakeOnLAN.formatMAC(mac), ip: ip, mask: mask, randomized: WakeOnLAN.isRandomized(mac))
        }.sorted { !$0.randomized && $1.randomized }
    }

    /// For /healthz: the network (so this Mac can wake others on it) and, when it's a real hardware
    /// address, what another Mac needs to wake this one. Nil without a usable network.
    static var json: [String: Any]? {
        guard let i = interfaces().first else { return nil }
        var o: [String: Any] = ["net": WakeOnLAN.network(ip: i.ip, mask: i.mask)]
        if !i.randomized { o["mac"] = i.mac }
        return o
    }

    /// Sends the magic packet for `mac` on every network this Mac is on (and the general broadcast).
    static func wake(mac: [UInt8], port: UInt16 = 9) -> Bool {
        let packet = WakeOnLAN.packet(mac: mac)
        var ok = WakeOnLAN.send(packet, to: "255.255.255.255", port: port)
        for i in interfaces() { ok = WakeOnLAN.send(packet, to: WakeOnLAN.broadcast(ip: i.ip, mask: i.mask), port: port) || ok }
        return ok
    }
}
