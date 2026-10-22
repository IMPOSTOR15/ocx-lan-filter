import Foundation
import XCTest
@testable import LanModelCore

/// Swift writes the config, the real filter.py consumes it, Swift probes the result.
@MainActor
final class ContractTests: XCTestCase {
    var paths: Paths!
    var upstreamLog: URL!
    var procs: [Process] = []
    var upstreamPort = 0
    let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    override func setUp() async throws {
        paths = makeTempPaths()
        upstreamLog = paths.root.appendingPathComponent("upstream.log")
        FileManager.default.createFile(atPath: upstreamLog.path, contents: nil)
        upstreamPort = Self.freePort()
        let up = Process()
        up.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        up.arguments = ["python3", repo.appendingPathComponent("tests/fake_upstream.py").path, "\(upstreamPort)", upstreamLog.path]
        try up.run()
        procs.append(up)

        let f = Process()
        f.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        f.arguments = ["python3", repo.appendingPathComponent("filter.py").path]
        f.environment = ProcessInfo.processInfo.environment.merging([
            "OCX_LAN_FILTER_HOME": paths.root.path, "FILTER_RECONCILE_INTERVAL": "0.2"]) { $1 }
        f.standardError = FileHandle(forWritingAtPath: "/dev/null")
        try KeyStore(paths: paths).create("key")
        var cfg = sampleConfig(port: Self.freePort())
        cfg.endpoints[0].host = "127.0.0.1"
        cfg.upstream.port = upstreamPort
        try ConfigStore(paths: paths).save(cfg)
        try f.run()
        procs.append(f)
        try await waitFor("filter listening") { self.runtimeState("default") == "listening" }
        try await waitFor("fake upstream up") { Self.isOpen(self.upstreamPort) }
    }

    override func tearDown() async throws {
        procs.forEach { $0.terminate() }
        procs.forEach { $0.waitUntilExit() }
    }

    static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    static func isOpen(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = UInt16(port).bigEndian
        return withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 } }
    }

    func runtimeState(_ id: String) -> String? {
        if case .ok(let rt) = RuntimeStatusReader(paths: paths).read() { return rt.endpoints[id]?.state.rawValue }
        return nil
    }

    func waitFor(_ what: String, timeout: TimeInterval = 8, _ cond: @escaping () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return }
            try await Task.sleep(nanoseconds: 80_000_000)
        }
        XCTFail("timeout waiting for \(what)")
    }

    func upstreamModels() -> [String] {
        let text = (try? String(contentsOf: upstreamLog)) ?? ""
        return text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["model"] as? String
        }
    }

    func makeModel() -> AppModel {
        let deps = Dependencies(paths: paths, ocx: { OCXClient(host: $0.host, port: $0.port) })
        let m = AppModel(deps: deps)
        m.reloadFiles()
        return m
    }

    // C-01 + C-04
    func testFilterAcceptsSwiftConfigAndPublishesRuntime() throws {
        guard case .ok(let rt) = RuntimeStatusReader(paths: paths).read() else { return XCTFail() }
        XCTAssertNil(rt.configError)
        XCTAssertEqual(rt.filterVersion, 2)
        XCTAssertTrue(RuntimeStatusReader.processAlive(rt.pid))
    }

    // C-02
    func testSetModelReachesUpstreamOnNextRequest() async throws {
        let m = makeModel()
        let port = m.config.endpoints[0].port
        let key = try XCTUnwrap(m.key(for: "default"))
        let r1 = await m.deps.probe.probe(port: port, alias: "local-llm", key: key)
        guard case .ok(let model, _, _) = r1 else { return XCTFail("\(r1)") }
        XCTAssertEqual(model, "m/one")
        XCTAssertTrue(m.setModel(endpoint: "default", alias: "local-llm", model: "m/two"))
        let r2 = await m.deps.probe.probe(port: port, alias: "local-llm", key: key)
        guard case .ok(let model2, _, _) = r2 else { return XCTFail("\(r2)") }
        XCTAssertEqual(model2, "m/two")
        XCTAssertEqual(upstreamModels(), ["m/one", "m/two"])
    }

    // C-03
    func testNewEndpointWithGeneratedKey() async throws {
        let m = makeModel()
        let port = ConfigValidator.nextFreePort(in: m.config, from: Self.freePort() + 1)
        let ep = Endpoint(id: "lap", name: "Laptop", host: "127.0.0.1", port: port, keyFile: "keys/lap.key",
                          aliases: [AliasMapping(alias: "fast", model: "m/fast"), AliasMapping(alias: "slow", model: "m/slow")])
        XCTAssertTrue(m.addEndpoint(ep), m.lastError ?? "")
        try await waitFor("new endpoint listening") { self.runtimeState("lap") == "listening" }

        let key = try XCTUnwrap(m.key(for: "lap"))
        let ok = await m.deps.probe.probe(port: port, alias: "fast", key: key)
        guard case .ok(let model, _, _) = ok else { return XCTFail("\(ok)") }
        XCTAssertEqual(model, "m/fast")

        let other = try XCTUnwrap(m.key(for: "default"))
        let wrongKey = await m.deps.probe.probe(port: port, alias: "fast", key: other)
        guard case .failed(let m401) = wrongKey else { return XCTFail("\(wrongKey)") }
        XCTAssertTrue(m401.hasPrefix("401: wrong or missing key"), m401)
        let wrongAlias = await m.deps.probe.probe(port: port, alias: "local-llm", key: key)
        guard case .failed(let msg) = wrongAlias else { return XCTFail("\(wrongAlias)") }
        XCTAssertTrue(msg.hasPrefix("403"), msg)

        XCTAssertTrue(m.setEnabled(endpoint: "lap", false))
        try await waitFor("endpoint closed") { !Self.isOpen(port) }
    }

    func testKeyRotationTakesEffectWithoutRestart() async throws {
        let m = makeModel()
        let port = m.config.endpoints[0].port
        let old = try XCTUnwrap(m.key(for: "default"))
        let new = try XCTUnwrap(m.rotateKey(endpoint: "default"))
        let withOld = await m.deps.probe.probe(port: port, alias: "local-llm", key: old)
        guard case .failed(let m401) = withOld else { return XCTFail("\(withOld)") }
        XCTAssertTrue(m401.hasPrefix("401"), m401)
        let withNew = await m.deps.probe.probe(port: port, alias: "local-llm", key: new)
        guard case .ok = withNew else { return XCTFail("\(withNew)") }
    }

    func testInvalidExternalEditIsReportedByFilterAndTrafficContinues() async throws {
        let m = makeModel()
        try "{ nope".write(to: paths.config, atomically: true, encoding: .utf8)
        try await waitFor("configError") {
            if case .ok(let rt) = RuntimeStatusReader(paths: self.paths).read() { return rt.configError != nil }
            return false
        }
        let key = try XCTUnwrap(m.key(for: "default"))
        let r = await m.deps.probe.probe(port: m.config.endpoints[0].port, alias: "local-llm", key: key)
        guard case .ok = r else { return XCTFail("\(r)") }
    }
}
