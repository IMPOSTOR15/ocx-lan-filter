import Foundation

public struct ValidationIssue: Equatable, Sendable, CustomStringConvertible {
    public let path: String
    public let message: String
    public var description: String { path.isEmpty ? message : "\(path): \(message)" }
    public init(_ path: String, _ message: String) {
        self.path = path
        self.message = message
    }
}

/// Mirrors `validate()` in filter.py. Both are checked against tests/fixtures/validation.json.
public enum ConfigValidator {
    public static let idPattern = #"^[a-z0-9][a-z0-9-]{0,31}$"#
    public static let aliasPattern = #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$"#

    static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) != nil
    }

    public static func isValidID(_ s: String) -> Bool { matches(s, idPattern) }
    public static func isValidAlias(_ s: String) -> Bool { matches(s, aliasPattern) }

    public static func isValidKeyFile(_ kf: String) -> Bool {
        !kf.isEmpty && !kf.contains("\0") && !kf.hasPrefix("/") && !kf.hasSuffix("/")
            && !kf.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    public static func validate(_ cfg: ProxyConfig) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        if cfg.version != 2 { issues.append(.init("version", "must be 2")) }
        if cfg.upstream.host != "127.0.0.1" { issues.append(.init("upstream.host", "must be 127.0.0.1")) }
        var upPort: Int? = cfg.upstream.port
        if !(1...65535).contains(cfg.upstream.port) {
            issues.append(.init("upstream.port", "must be 1..65535"))
            upPort = nil
        }
        var seenIDs = Set<String>()
        var seenPorts = Set<Int>()
        for (i, ep) in cfg.endpoints.enumerated() {
            let p = "endpoints[\(i)]"
            if !isValidID(ep.id) {
                issues.append(.init(p + ".id", "must match \(idPattern)"))
            } else if !seenIDs.insert(ep.id).inserted {
                issues.append(.init(p + ".id", "duplicate id"))
            }
            if !(1...64).contains(ep.name.count) { issues.append(.init(p + ".name", "must be 1..64 characters")) }
            if ListenScope(rawValue: ep.host) == nil { issues.append(.init(p + ".host", "must be 0.0.0.0 or 127.0.0.1")) }
            if !(1024...65535).contains(ep.port) {
                issues.append(.init(p + ".port", "must be 1024..65535"))
            } else if seenPorts.contains(ep.port) {
                issues.append(.init(p + ".port", "duplicate port"))
            } else if ep.port == upPort {
                issues.append(.init(p + ".port", "conflicts with the upstream port"))
            } else {
                seenPorts.insert(ep.port)
            }
            if !isValidKeyFile(ep.keyFile) {
                issues.append(.init(p + ".keyFile", "must be a relative path inside the state directory"))
            }
            if ep.aliases.isEmpty {
                issues.append(.init(p + ".aliases", "at least one alias required"))
                continue
            }
            var seenAliases = Set<String>()
            for (j, a) in ep.aliases.enumerated() {
                let ap = "\(p).aliases[\(j)]"
                if !isValidAlias(a.alias) {
                    issues.append(.init(ap + ".alias", "must match \(aliasPattern)"))
                } else if !seenAliases.insert(a.alias).inserted {
                    issues.append(.init(ap + ".alias", "duplicate alias"))
                }
                let m = a.model.trimmingCharacters(in: .whitespacesAndNewlines)
                if m.isEmpty || a.model.count > 200 { issues.append(.init(ap + ".model", "must be 1..200 characters")) }
                if !(1...10_000_000).contains(a.contextLength) {
                    issues.append(.init(ap + ".contextLength", "must be 1..10000000"))
                }
            }
        }
        return issues
    }

    /// Port that is free of conflicts with `cfg`, starting at `from`.
    public static func nextFreePort(in cfg: ProxyConfig, from: Int = 10200) -> Int {
        let used = Set(cfg.endpoints.map(\.port) + [cfg.upstream.port])
        var p = from
        while used.contains(p) && p < 65535 { p += 1 }
        return p
    }

    public static func nextFreeID(in cfg: ProxyConfig, base: String = "endpoint") -> String {
        let used = Set(cfg.endpoints.map(\.id))
        if !used.contains(base) { return base }
        var n = 2
        while used.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }
}
