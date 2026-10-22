import CryptoKit
import Foundation

public enum ConfigStoreError: Error, Equatable, CustomStringConvertible {
    case invalid([ValidationIssue])
    case conflict
    case unreadable(String)

    public var description: String {
        switch self {
        case .invalid(let issues): return issues.map(\.description).joined(separator: "; ")
        case .conflict: return "config.json was changed on disk"
        case .unreadable(let m): return m
        }
    }
}

public struct LoadedConfig: Equatable, Sendable {
    public var config: ProxyConfig
    /// Hash of the bytes on disk; pass back to `save(expecting:)` to detect concurrent edits.
    public var fingerprint: String
    public var wasV1: Bool
}

public final class ConfigStore: @unchecked Sendable {
    public let paths: Paths
    private let fm = FileManager.default

    public init(paths: Paths) { self.paths = paths }

    static func fingerprint(_ data: Data?) -> String {
        guard let data else { return "missing" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public func currentFingerprint() -> String {
        Self.fingerprint(try? Data(contentsOf: paths.config))
    }

    public func load() throws -> LoadedConfig {
        guard let data = try? Data(contentsOf: paths.config) else {
            return LoadedConfig(config: ProxyConfig.migratedFromV1(model: nil), fingerprint: "missing", wasV1: true)
        }
        let fp = Self.fingerprint(data)
        let obj: Any
        do { obj = try JSONSerialization.jsonObject(with: data) } catch {
            throw ConfigStoreError.unreadable("config.json is not valid JSON: \(error.localizedDescription)")
        }
        guard let dict = obj as? [String: Any] else { throw ConfigStoreError.unreadable("config.json must be an object") }
        if dict["version"] == nil && dict["endpoints"] == nil {
            let cfg = ProxyConfig.migratedFromV1(model: dict["upstream_model"] as? String)
            return LoadedConfig(config: cfg, fingerprint: fp, wasV1: true)
        }
        do {
            let cfg = try JSONDecoder().decode(ProxyConfig.self, from: data)
            return LoadedConfig(config: cfg, fingerprint: fp, wasV1: false)
        } catch {
            throw ConfigStoreError.unreadable("config.json has the wrong shape: \(error)")
        }
    }

    /// Validates, then writes atomically. Returns the new fingerprint.
    @discardableResult
    public func save(_ config: ProxyConfig, expecting fingerprint: String? = nil) throws -> String {
        let issues = ConfigValidator.validate(config)
        guard issues.isEmpty else { throw ConfigStoreError.invalid(issues) }
        if let fingerprint, fingerprint != currentFingerprint() { throw ConfigStoreError.conflict }

        var out = config
        var normalized = out.endpoints
        for i in normalized.indices {
            for j in normalized[i].aliases.indices {
                normalized[i].aliases[j].model = normalized[i].aliases[j].model.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        out.endpoints = normalized
        let primary = out.endpoint("default") ?? out.endpoints.first
        out.upstreamModelMirror = primary?.aliases.first?.model

        try fm.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try backupV1IfNeeded()

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try enc.encode(out)
        let tmp = paths.root.appendingPathComponent("config.json.tmp.\(ProcessInfo.processInfo.processIdentifier)")
        try data.write(to: tmp)
        _ = try fm.replaceItemAt(paths.config, withItemAt: tmp)
        return Self.fingerprint(data)
    }

    private func backupV1IfNeeded() throws {
        guard !fm.fileExists(atPath: paths.configBackupV1.path),
              let existing = try? Data(contentsOf: paths.config),
              let dict = try? JSONSerialization.jsonObject(with: existing) as? [String: Any],
              dict["version"] == nil, dict["endpoints"] == nil else { return }
        try existing.write(to: paths.configBackupV1)
    }
}
