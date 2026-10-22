import Foundation
import XCTest
@testable import LanModelCore

func makeTempPaths() -> Paths {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lmb-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return Paths(root: dir)
}

func sampleConfig(port: Int = 10200, model: String = "m/one") -> ProxyConfig {
    ProxyConfig(endpoints: [Endpoint(id: "default", name: "Home", port: port, keyFile: "key",
                                     aliases: [AliasMapping(alias: "local-llm", model: model)])])
}

final class FakeTransport: HTTPTransport, @unchecked Sendable {
    var handler: (URLRequest) throws -> (Int, Data)
    private(set) var requests: [URLRequest] = []
    init(_ handler: @escaping (URLRequest) throws -> (Int, Data)) { self.handler = handler }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let (code, data) = try handler(request)
        return (data, HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
    }
}

func json(_ obj: Any) -> Data { try! JSONSerialization.data(withJSONObject: obj) }

final class FakeRunner: CommandRunner, @unchecked Sendable {
    var results: [CommandResult] = []
    private(set) var calls: [[String]] = []
    func run(_ launchPath: String, _ args: [String], environment: [String: String]?) async -> CommandResult {
        calls.append([launchPath] + args)
        return results.isEmpty ? CommandResult(status: 0, output: "") : results.removeFirst()
    }
}
