import Foundation
import Security

public enum KeyStoreError: Error, CustomStringConvertible {
    case randomFailed
    case invalidPath
    public var description: String {
        switch self {
        case .randomFailed: return "secure random generator failed"
        case .invalidPath: return "invalid key path"
        }
    }
}

/// Opaque wrapper so a key never ends up in a log or an error message through string interpolation.
public struct SecretKey: CustomStringConvertible, CustomDebugStringConvertible, Sendable, Equatable {
    public let value: String
    public init(_ value: String) { self.value = value }
    public var description: String { masked }
    public var debugDescription: String { masked }
    public var masked: String {
        guard value.count > 4 else { return "••••" }
        let prefix = value.hasPrefix("lan_") ? "lan_" : ""
        return prefix + "••••••••"
    }
}

public final class KeyStore: @unchecked Sendable {
    public let paths: Paths
    private let fm = FileManager.default

    public init(paths: Paths) { self.paths = paths }

    public static func generate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw KeyStoreError.randomFailed
        }
        let b64 = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "lan_" + b64
    }

    public static func defaultKeyFile(forEndpoint id: String) -> String { "keys/\(id).key" }

    public func exists(_ relative: String) -> Bool {
        ConfigValidator.isValidKeyFile(relative) && fm.fileExists(atPath: paths.keyURL(relative).path)
    }

    public func read(_ relative: String) throws -> SecretKey {
        guard ConfigValidator.isValidKeyFile(relative) else { throw KeyStoreError.invalidPath }
        let s = try String(contentsOf: paths.keyURL(relative), encoding: .utf8)
        return SecretKey(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Writes a fresh key with 0600 (directory 0700). Replaces an existing file.
    @discardableResult
    public func create(_ relative: String) throws -> SecretKey {
        guard ConfigValidator.isValidKeyFile(relative) else { throw KeyStoreError.invalidPath }
        let url = paths.keyURL(relative)
        let dir = url.deletingLastPathComponent()
        let isNested = dir.standardizedFileURL != paths.root.standardizedFileURL
        if isNested {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        } else {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let key = try Self.generate()
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp")
        fm.createFile(atPath: tmp.path, contents: Data(key.utf8), attributes: [.posixPermissions: 0o600])
        _ = try fm.replaceItemAt(url, withItemAt: tmp)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return SecretKey(key)
    }

    public func rotate(_ relative: String) throws -> SecretKey { try create(relative) }

    public func remove(_ relative: String) {
        guard ConfigValidator.isValidKeyFile(relative) else { return }
        try? fm.removeItem(at: paths.keyURL(relative))
    }
}
