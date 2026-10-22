import Foundation

public enum NetworkInfo {
    /// First IPv4 address of `en0` (Wi-Fi on a laptop), or nil.
    public static func lanIPv4(interface: String = "en0") -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var cur: UnsafeMutablePointer<ifaddrs>? = first
        while let p = cur {
            defer { cur = p.pointee.ifa_next }
            guard let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  String(cString: p.pointee.ifa_name) == interface else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }

    public static func baseURL(for ep: Endpoint, lanIP: String?) -> String {
        let host = ep.scope == .localOnly ? "127.0.0.1" : (lanIP ?? "<ip>")
        return "http://\(host):\(ep.port)/v1"
    }

    public static func curlExample(for ep: Endpoint, lanIP: String?) -> String {
        let alias = ep.aliases.first?.alias ?? "alias"
        return """
        curl -s \(baseURL(for: ep, lanIP: lanIP))/chat/completions \\
          -H "Authorization: Bearer $(cat ~/.local/share/ocx-lan-filter/\(ep.keyFile))" \\
          -H "Content-Type: application/json" \\
          -d '{"model":"\(alias)","messages":[{"role":"user","content":"2+2?"}]}'
        """
    }
}
