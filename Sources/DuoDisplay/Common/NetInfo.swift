import Foundation
import SystemConfiguration
import Darwin

/// A network interface that is up and has an address.
struct NetLink: Hashable, Identifiable {
    let name: String
    let ipv4: String?
    let hasIPv6: Bool
    let mtu: Int
    let isThunderbolt: Bool
    var id: String { name }

    var summary: String {
        var parts = [name]
        if let ipv4 { parts.append(ipv4) } else if hasIPv6 { parts.append("IPv6 link-local") }
        parts.append("MTU \(mtu)" + (mtu >= 9000 ? " (Jumbo)" : ""))
        return parts.joined(separator: " · ")
    }
}

enum NetInfo {
    /// BSD names of interfaces macOS labels as Thunderbolt (e.g. "Thunderbolt 1" = en1).
    static func thunderboltNames() -> Set<String> {
        var names = Set<String>()
        if let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for iface in all {
                guard let bsd = SCNetworkInterfaceGetBSDName(iface) as String? else { continue }
                let display = (SCNetworkInterfaceGetLocalizedDisplayName(iface) as String?) ?? ""
                if display.localizedCaseInsensitiveContains("thunderbolt") { names.insert(bsd) }
            }
        }
        return names
    }

    /// "Thunderbolt Bridge" is `bridge0`; a bare Thunderbolt IP interface is `enX` labelled "Thunderbolt".
    /// Other bridges (bridge100… from Internet Sharing or VMs) are not Thunderbolt.
    static func isThunderbolt(_ name: String, tbNames: Set<String>) -> Bool {
        name == "bridge0" || tbNames.contains(name)
    }

    static func links() -> [NetLink] {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
        defer { freeifaddrs(ifap) }

        struct Acc { var flags: UInt32 = 0; var ipv4: String?; var v6 = false; var mtu = 1500 }
        var acc: [String: Acc] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let p = cursor {
            let ifa = p.pointee
            cursor = ifa.ifa_next
            let name = String(cString: ifa.ifa_name)
            var a = acc[name] ?? Acc()
            a.flags = ifa.ifa_flags
            if let addr = ifa.ifa_addr {
                switch Int32(addr.pointee.sa_family) {
                case AF_INET:
                    var sin = UnsafeRawPointer(addr).loadUnaligned(as: sockaddr_in.self)
                    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
                    a.ipv4 = String(cString: buf)
                case AF_INET6:
                    a.v6 = true
                case AF_LINK:
                    if let data = ifa.ifa_data {
                        a.mtu = Int(data.assumingMemoryBound(to: if_data.self).pointee.ifi_mtu)
                    }
                default: break
                }
            }
            acc[name] = a
        }

        let tb = thunderboltNames()
        let required = UInt32(IFF_UP | IFF_RUNNING)
        return acc.compactMap { name, a in
            guard a.flags & required == required, a.flags & UInt32(IFF_LOOPBACK) == 0,
                  a.ipv4 != nil || a.v6 else { return nil }
            return NetLink(name: name, ipv4: a.ipv4, hasIPv6: a.v6, mtu: a.mtu,
                           isThunderbolt: isThunderbolt(name, tbNames: tb))
        }.sorted { $0.name < $1.name }
    }

    static func thunderboltLinks() -> [NetLink] { links().filter(\.isThunderbolt) }

    static func mtu(of name: String) -> Int? {
        links().first { $0.name == name }?.mtu
    }
}
