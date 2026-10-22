import Foundation

public struct AliasMapping: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var alias: String
    public var model: String
    public var contextLength: Int
    public var id: String { alias }

    public static let defaultContextLength = 1_000_000

    public init(alias: String, model: String, contextLength: Int = AliasMapping.defaultContextLength) {
        self.alias = alias
        self.model = model
        self.contextLength = contextLength
    }

    enum CodingKeys: String, CodingKey { case alias, model, contextLength }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        alias = try c.decode(String.self, forKey: .alias)
        model = try c.decode(String.self, forKey: .model)
        contextLength = try c.decodeIfPresent(Int.self, forKey: .contextLength) ?? Self.defaultContextLength
    }
}

public enum ListenScope: String, Sendable, CaseIterable {
    case lan = "0.0.0.0"
    case localOnly = "127.0.0.1"
}

public struct Endpoint: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var enabled: Bool
    public var host: String
    public var port: Int
    public var keyFile: String
    public var aliases: [AliasMapping]

    public init(id: String, name: String, enabled: Bool = true, host: String = ListenScope.lan.rawValue,
                port: Int, keyFile: String, aliases: [AliasMapping]) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.host = host
        self.port = port
        self.keyFile = keyFile
        self.aliases = aliases
    }

    public var scope: ListenScope {
        get { ListenScope(rawValue: host) ?? .lan }
        set { host = newValue.rawValue }
    }
}

public struct Upstream: Codable, Equatable, Hashable, Sendable {
    public var host: String
    public var port: Int
    public init(host: String = "127.0.0.1", port: Int = 10100) {
        self.host = host
        self.port = port
    }
}

public struct ProxyConfig: Codable, Equatable, Sendable {
    public var version: Int
    public var upstream: Upstream
    public var endpoints: [Endpoint]
    /// Mirror of the first alias of the `default` endpoint, so a v1 `filter.py` / `lanmodel` still works.
    public var upstreamModelMirror: String?

    public init(version: Int = 2, upstream: Upstream = Upstream(), endpoints: [Endpoint] = []) {
        self.version = version
        self.upstream = upstream
        self.endpoints = endpoints
    }

    enum CodingKeys: String, CodingKey {
        case version, upstream, endpoints
        case upstreamModelMirror = "upstream_model"
    }

    public func endpoint(_ id: String) -> Endpoint? { endpoints.first { $0.id == id } }

    public static func migratedFromV1(model: String?, host: String = "0.0.0.0", port: Int = 10200,
                                      upstreamPort: Int = 10100) -> ProxyConfig {
        let m = (model?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 }
            ?? "unset/choose-a-model"
        let ep = Endpoint(id: "default", name: "default", host: host, port: port, keyFile: "key",
                          aliases: [AliasMapping(alias: "local-llm", model: m)])
        return ProxyConfig(upstream: Upstream(port: upstreamPort), endpoints: [ep])
    }
}
