import Darwin

/// Resolves the machine's preferred LAN IPv4 address for the Web UI.
///
/// The daemon listens on `0.0.0.0:8789`, so the loopback URL shown in the Web
/// panel can be rewritten to a phone-reachable address. `en*` interfaces
/// (Wi-Fi/Ethernet) are preferred over VPN and tunnel adapters so the copied
/// URL follows the network the machine actually uses.
enum WarrenLANAddress {
    static func primaryIPv4() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }

        var preferred: String?
        var fallback: String?

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(current.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let ip = numericIPv4(address) else { continue }
            guard !isLinkLocal(ip) else { continue }

            if fallback == nil {
                fallback = ip
            }
            if preferred == nil,
               cString(current.pointee.ifa_name).hasPrefix("en") {
                preferred = ip
            }
        }
        return preferred ?? fallback
    }

    private static func numericIPv4(_ address: UnsafeMutablePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(
            address,
            socklen_t(address.pointee.sa_len),
            &host,
            socklen_t(host.count),
            nil,
            0,
            NI_NUMERICHOST
        )
        guard result == 0 else { return nil }
        return host.withUnsafeBufferPointer { buffer in
            buffer.withMemoryRebound(to: UInt8.self) { bytes in
                String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
        }
    }

    private static func cString(_ pointer: UnsafePointer<CChar>) -> String {
        var bytes: [UInt8] = []
        var cursor = pointer
        while cursor.pointee != 0 {
            bytes.append(UInt8(bitPattern: cursor.pointee))
            cursor = cursor.advanced(by: 1)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func isLinkLocal(_ ip: String) -> Bool {
        ip.hasPrefix("169.254.") || ip.hasPrefix("fe80:")
    }
}
