import Foundation

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession
    public init(timeout: TimeInterval = 10) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout * 2
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.connectionProxyDictionary = [:]  // loopback / LAN targets must bypass any system proxy
        session = URLSession(configuration: cfg)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, resp) = try await session.data(for: request)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

public struct OCXModel: Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public let contextLength: Int?
}

public enum OCXError: Error, Equatable, CustomStringConvertible {
    case unreachable(String)
    case http(Int)
    case badPayload

    public var description: String {
        switch self {
        case .unreachable(let m): return "ocx is unreachable: \(m)"
        case .http(let c): return "ocx answered HTTP \(c)"
        case .badPayload: return "ocx returned an unexpected payload"
        }
    }
}

public struct OCXClient: Sendable {
    public let baseURL: URL
    private let transport: HTTPTransport

    public init(host: String = "127.0.0.1", port: Int = 10100, transport: HTTPTransport = URLSessionTransport()) {
        self.baseURL = URL(string: "http://\(host):\(port)")!
        self.transport = transport
    }

    public func models() async throws -> [OCXModel] {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/models"))
        req.timeoutInterval = 5
        let data: Data
        let resp: HTTPURLResponse
        do { (data, resp) = try await transport.send(req) } catch {
            throw OCXError.unreachable((error as? URLError)?.localizedDescription ?? "\(error)")
        }
        guard resp.statusCode == 200 else { throw OCXError.http(resp.statusCode) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["data"] as? [[String: Any]] else { throw OCXError.badPayload }
        return list.compactMap { item -> OCXModel? in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            let ctx = (item["capabilities"] as? [String: Any])?["context_length"] as? Int
            return OCXModel(id: id, contextLength: ctx)
        }.sorted { $0.id < $1.id }
    }
}
