import Foundation

public enum EndpointState: String, Codable, Sendable {
    case listening, disabled, error
}

public struct EndpointRuntime: Codable, Equatable, Sendable {
    public var host: String
    public var port: Int
    public var state: EndpointState
    public var error: String?
}

public struct RuntimeStatus: Codable, Equatable, Sendable {
    public var filterVersion: Int
    public var pid: Int
    public var startedAt: String?
    public var configMtime: Double?
    public var configError: String?
    public var endpoints: [String: EndpointRuntime]
}

public enum RuntimeReadResult: Equatable, Sendable {
    case missing
    case unreadable
    case outdated(Int)
    case ok(RuntimeStatus)
}

public struct RuntimeStatusReader: Sendable {
    public static let requiredVersion = 2
    public let paths: Paths
    public init(paths: Paths) { self.paths = paths }

    public func read() -> RuntimeReadResult {
        guard let data = try? Data(contentsOf: paths.runtime) else { return .missing }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let v = obj["filterVersion"] as? Int, v < Self.requiredVersion {
            return .outdated(v)
        }
        guard let status = try? JSONDecoder().decode(RuntimeStatus.self, from: data) else { return .unreadable }
        return .ok(status)
    }

    public static func processAlive(_ pid: Int) -> Bool {
        pid > 0 && kill(pid_t(pid), 0) == 0
    }
}
