import Foundation

public enum ProbeResult: Equatable, Sendable {
    case ok(model: String, answer: String, seconds: Double)
    case failed(String)
}

public struct EndpointProbe: Sendable {
    private let transport: HTTPTransport
    public init(transport: HTTPTransport = URLSessionTransport(timeout: 60)) { self.transport = transport }

    public func probe(port: Int, alias: String, key: SecretKey) async -> ProbeResult {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("Bearer \(key.value)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": alias,
            "messages": [["role": "user", "content": "What is 2+2? Just the number."]],
            "max_tokens": 200,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let t0 = Date()
        do {
            let (data, resp) = try await transport.send(req)
            let secs = Date().timeIntervalSince(t0)
            guard resp.statusCode == 200 else { return .failed(Self.describe(resp.statusCode, data)) }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failed("unexpected response")
            }
            let model = obj["model"] as? String ?? "?"
            let msg = ((obj["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String ?? ""
            return .ok(model: model, answer: msg.trimmingCharacters(in: .whitespacesAndNewlines), seconds: secs)
        } catch {
            return .failed((error as? URLError)?.localizedDescription ?? "\(error)")
        }
    }

    static func describe(_ status: Int, _ data: Data) -> String {
        let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
            .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
        let base: String
        switch status {
        case 401: base = "401: wrong or missing key"
        case 403: base = "403: alias is not exposed by this endpoint"
        case 502: base = "502: ocx or the upstream provider is unavailable"
        default: base = "HTTP \(status)"
        }
        return detail.map { "\(base) (\($0.prefix(200)))" } ?? base
    }
}
