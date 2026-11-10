import Foundation

enum NetUtils {
    /// 取本机 WiFi/蜂窝 IPv4，仅用于界面展示。
    static func localIPv4() -> String {
        var result = "127.0.0.1"
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return result }
        defer { freeifaddrs(head) }
        var cur: UnsafeMutablePointer<ifaddrs>? = first
        while let p = cur {
            defer { cur = p.pointee.ifa_next }
            guard let sa = p.pointee.ifa_addr else { continue }
            let flags = Int32(p.pointee.ifa_flags)
            let addr = sa.pointee
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0, addr.sa_family == sa_family_t(AF_INET) else { continue }
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let rc = withUnsafePointer(to: addr) { ptr in
                getnameinfo(ptr, socklen_t(addr.sa_len), &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST)
            }
            if rc == 0 { result = String(cString: buf); break }
        }
        return result
    }
}

enum RSUtil {
    static func mime(_ path: String) -> String {
        if path.hasSuffix(".html") { return "text/html; charset=utf-8" }
        if path.hasSuffix(".css") { return "text/css; charset=utf-8" }
        if path.hasSuffix(".js") { return "application/javascript; charset=utf-8" }
        if path.hasSuffix(".json") { return "application/json; charset=utf-8" }
        return "application/octet-stream"
    }

    static func json(_ obj: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj, options: [])) ?? Data("{}".utf8)
    }
}
