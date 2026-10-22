import Foundation

public struct Paths: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public static func standard() -> Paths {
        if let env = ProcessInfo.processInfo.environment["OCX_LAN_FILTER_HOME"], !env.isEmpty {
            return Paths(root: URL(fileURLWithPath: env, isDirectory: true))
        }
        return Paths(root: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/ocx-lan-filter", isDirectory: true))
    }

    public var config: URL { root.appendingPathComponent("config.json") }
    public var configBackupV1: URL { root.appendingPathComponent("config.json.bak-v1") }
    public var runtime: URL { root.appendingPathComponent("runtime.json") }
    public var log: URL { root.appendingPathComponent("filter.log") }
    public var keysDir: URL { root.appendingPathComponent("keys", isDirectory: true) }

    public func keyURL(_ relative: String) -> URL { root.appendingPathComponent(relative) }
}
