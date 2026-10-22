import XCTest
@testable import LanModelCore

final class ClientTests: XCTestCase {
    // S-07
    func testOCXModelsSortedWithContext() async throws {
        let t = FakeTransport { _ in
            (200, json(["data": [["id": "b", "capabilities": ["context_length": 512000]], ["id": "a"], ["nope": 1], ["id": ""]]]))
        }
        let models = try await OCXClient(transport: t).models()
        XCTAssertEqual(models.map(\.id), ["a", "b"])
        XCTAssertEqual(models[1].contextLength, 512000)
        XCTAssertEqual(t.requests[0].url?.absoluteString, "http://127.0.0.1:10100/v1/models")
    }

    func testOCXEmptyList() async throws {
        let t = FakeTransport { _ in (200, json(["data": []])) }
        let models = try await OCXClient(transport: t).models()
        XCTAssertEqual(models, [])
    }

    func testOCXFailures() async {
        func run(_ h: @escaping (URLRequest) throws -> (Int, Data)) async -> OCXError? {
            do { _ = try await OCXClient(transport: FakeTransport(h)).models(); return nil } catch { return error as? OCXError }
        }
        let http500 = await run { _ in (500, Data()) }
        XCTAssertEqual(http500, .http(500))
        let garbage = await run { _ in (200, Data("not json".utf8)) }
        XCTAssertEqual(garbage, .badPayload)
        let wrongShape = await run { _ in (200, json(["models": []])) }
        XCTAssertEqual(wrongShape, .badPayload)
        let timeout = await run { _ in throw URLError(.timedOut) }
        guard case .unreachable = timeout else { return XCTFail("\(String(describing: timeout))") }
    }

    // S-10
    func testProbeOutcomes() async {
        let key = SecretKey("lan_k")
        let okT = FakeTransport { _ in
            (200, json(["model": "real/m", "choices": [["message": ["content": " 4 "]]]]))
        }
        let ok = await EndpointProbe(transport: okT).probe(port: 10200, alias: "local-llm", key: key)
        guard case .ok(let model, let answer, _) = ok else { return XCTFail("\(ok)") }
        XCTAssertEqual([model, answer], ["real/m", "4"])
        let sent = okT.requests[0]
        XCTAssertEqual(sent.url?.absoluteString, "http://127.0.0.1:10200/v1/chat/completions")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer lan_k")
        XCTAssertEqual((try? JSONSerialization.jsonObject(with: sent.httpBody!) as? [String: Any])?["model"] as? String, "local-llm")

        for (code, needle) in [(401, "key"), (403, "alias"), (502, "unavailable"), (418, "418")] {
            let t = FakeTransport { _ in (code, json(["error": ["message": "detail"]])) }
            let r = await EndpointProbe(transport: t).probe(port: 1, alias: "a", key: key)
            guard case .failed(let msg) = r else { return XCTFail("\(r)") }
            XCTAssertTrue(msg.contains(needle), msg)
            XCTAssertTrue(msg.contains("detail"))
        }
        let timeout = await EndpointProbe(transport: FakeTransport { _ in throw URLError(.timedOut) })
            .probe(port: 1, alias: "a", key: key)
        guard case .failed = timeout else { return XCTFail("\(timeout)") }
        let junk = await EndpointProbe(transport: FakeTransport { _ in (200, Data("x".utf8)) })
            .probe(port: 1, alias: "a", key: key)
        XCTAssertEqual(junk, .failed("unexpected response"))
    }

    // S-08
    func testRuntimeReader() throws {
        let p = makeTempPaths()
        let r = RuntimeStatusReader(paths: p)
        XCTAssertEqual(r.read(), .missing)
        try "garbage".write(to: p.runtime, atomically: true, encoding: .utf8)
        XCTAssertEqual(r.read(), .unreadable)
        try #"{"filterVersion":1,"pid":1}"#.write(to: p.runtime, atomically: true, encoding: .utf8)
        XCTAssertEqual(r.read(), .outdated(1))
        try """
        {"filterVersion":2,"pid":42,"startedAt":"t","configMtime":1.5,"configError":null,
         "endpoints":{"default":{"host":"0.0.0.0","port":10200,"state":"listening","error":null},
                      "b":{"host":"127.0.0.1","port":10201,"state":"error","error":"address already in use"}}}
        """.write(to: p.runtime, atomically: true, encoding: .utf8)
        guard case .ok(let s) = r.read() else { return XCTFail() }
        XCTAssertEqual(s.pid, 42)
        XCTAssertEqual(s.endpoints["default"]?.state, .listening)
        XCTAssertEqual(s.endpoints["b"]?.error, "address already in use")
        XCTAssertTrue(RuntimeStatusReader.processAlive(Int(getpid())))
    }

    // S-09
    func testServiceParsing() {
        let running = CommandResult(status: 0, output: """
        gui/501/com.local.ocx-lan-filter = {
        \tstate = running
        \tpid = 4553
        \tjob state = running
        }
        """)
        XCTAssertEqual(ServiceController.parse(running), .running(pid: 4553))
        XCTAssertEqual(ServiceController.parse(CommandResult(status: 0, output: "\tstate = not running\n")), .stopped)
        XCTAssertEqual(ServiceController.parse(CommandResult(status: 113, output: "Could not find service")), .notInstalled)
    }

    func testServiceCommands() async {
        let runner = FakeRunner()
        let missing = URL(fileURLWithPath: "/nonexistent/x.plist")
        let svc = ServiceController(runner: runner, uid: 501, plist: missing)
        runner.results = [CommandResult(status: 113, output: "")]
        let s = await svc.state()
        XCTAssertEqual(s, .notInstalled)
        _ = await svc.restart()
        _ = await svc.stop()
        XCTAssertEqual(runner.calls[0], ["/bin/launchctl", "print", "gui/501/com.local.ocx-lan-filter"])
        XCTAssertEqual(runner.calls[1], ["/bin/launchctl", "kickstart", "-k", "gui/501/com.local.ocx-lan-filter"])
        XCTAssertEqual(runner.calls[2], ["/bin/launchctl", "bootout", "gui/501/com.local.ocx-lan-filter"])
    }

    func testProcessRunnerRunsRealCommand() async {
        let r = await ProcessRunner().run("/bin/echo", ["hi"], environment: nil)
        XCTAssertEqual(r, CommandResult(status: 0, output: "hi\n"))
        let bad = await ProcessRunner().run("/nonexistent", [], environment: nil)
        XCTAssertEqual(bad.status, 127)
    }

    // S-11
    func testNetworkInfo() {
        XCTAssertNil(NetworkInfo.lanIPv4(interface: "definitely-not-an-interface"))
        if let ip = NetworkInfo.lanIPv4(interface: "lo0") { XCTAssertEqual(ip, "127.0.0.1") }
        let ep = Endpoint(id: "a", name: "A", port: 10200, keyFile: "key", aliases: [AliasMapping(alias: "x", model: "m")])
        XCTAssertEqual(NetworkInfo.baseURL(for: ep, lanIP: "192.0.2.10"), "http://192.0.2.10:10200/v1")
        XCTAssertEqual(NetworkInfo.baseURL(for: ep, lanIP: nil), "http://<ip>:10200/v1")
        var local = ep; local.scope = .localOnly
        XCTAssertEqual(NetworkInfo.baseURL(for: local, lanIP: "192.0.2.10"), "http://127.0.0.1:10200/v1")
        XCTAssertTrue(NetworkInfo.curlExample(for: ep, lanIP: "1.2.3.4").contains("\"model\":\"x\""))
    }
}
