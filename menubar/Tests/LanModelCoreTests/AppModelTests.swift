import XCTest
@testable import LanModelCore

@MainActor
final class AppModelTests: XCTestCase {
    func makeModel(models: [String] = ["m/one", "m/two"]) -> (AppModel, Paths, FakeRunner) {
        let paths = makeTempPaths()
        let runner = FakeRunner()
        let transport = FakeTransport { _ in (200, json(["data": models.map { ["id": $0] }])) }
        let deps = Dependencies(paths: paths,
                                service: ServiceController(runner: runner, uid: 501, plist: URL(fileURLWithPath: "/nonexistent")),
                                ocx: { OCXClient(host: $0.host, port: $0.port, transport: transport) },
                                lanIP: { "192.0.2.10" })
        return (AppModel(deps: deps), paths, runner)
    }

    // S-12
    func testSetModelWritesConfig() throws {
        let (m, paths, _) = makeModel()
        try ConfigStore(paths: paths).save(sampleConfig())
        try KeyStore(paths: paths).create("key")
        m.reloadFiles()
        XCTAssertTrue(m.setModel(endpoint: "default", alias: "local-llm", model: "m/two"))
        let disk = try ConfigStore(paths: paths).load().config
        XCTAssertEqual(disk.endpoints[0].aliases[0].model, "m/two")
        XCTAssertEqual(disk.upstreamModelMirror, "m/two")
        XCTAssertEqual(m.config.endpoints[0].aliases[0].model, "m/two")
    }

    func testInvalidChangeIsNotWritten() throws {
        let (m, paths, _) = makeModel()
        try ConfigStore(paths: paths).save(sampleConfig())
        m.reloadFiles()
        let before = try Data(contentsOf: paths.config)
        XCTAssertFalse(m.setModel(endpoint: "default", alias: "local-llm", model: "  "))
        XCTAssertNotNil(m.lastError)
        XCTAssertEqual(try Data(contentsOf: paths.config), before)
        XCTAssertFalse(m.mutate { $0.endpoints[0].port = 80 })
    }

    func testExternalEditIsPickedUp() throws {
        let (m, paths, _) = makeModel()
        let store = ConfigStore(paths: paths)
        try store.save(sampleConfig())
        m.reloadFiles()
        var ext = sampleConfig(); ext.endpoints[0].aliases[0].model = "external"
        try store.save(ext)
        m.reloadFiles()
        XCTAssertEqual(m.config.endpoints[0].aliases[0].model, "external")
    }

    func testBrokenFileKeepsLastConfigAndReports() throws {
        let (m, paths, _) = makeModel()
        try ConfigStore(paths: paths).save(sampleConfig())
        m.reloadFiles()
        try "{ nope".write(to: paths.config, atomically: true, encoding: .utf8)
        m.reloadFiles()
        XCTAssertNotNil(m.loadError)
        XCTAssertEqual(m.config.endpoints[0].aliases[0].model, "m/one")
    }

    func testConflictingCommitIsRejected() throws {
        let (m, paths, _) = makeModel()
        let store = ConfigStore(paths: paths)
        try store.save(sampleConfig())
        m.reloadFiles()
        let stale = m.fingerprint
        var ext = sampleConfig(); ext.endpoints[0].aliases[0].model = "external"
        try store.save(ext)
        var mine = m.config; mine.endpoints[0].aliases[0].model = "mine"
        XCTAssertFalse(m.commit(mine, expecting: stale))
        XCTAssertEqual(try store.load().config.endpoints[0].aliases[0].model, "external")
    }

    func testAddEndpointCreatesKeyAndRollsBackOnFailure() throws {
        let (m, paths, _) = makeModel()
        try ConfigStore(paths: paths).save(sampleConfig())
        m.reloadFiles()
        let good = Endpoint(id: "lap", name: "Laptop", port: 10201, keyFile: "keys/lap.key",
                            aliases: [AliasMapping(alias: "fast", model: "m/two")])
        XCTAssertTrue(m.addEndpoint(good))
        XCTAssertTrue(m.keys.exists("keys/lap.key"))
        XCTAssertEqual(m.config.endpoints.count, 2)

        let dup = Endpoint(id: "lap2", name: "Dup", port: 10201, keyFile: "keys/lap2.key",
                           aliases: [AliasMapping(alias: "x", model: "m/two")])
        XCTAssertFalse(m.addEndpoint(dup))
        XCTAssertFalse(m.keys.exists("keys/lap2.key"), "key of a rejected endpoint must not stay on disk")
        XCTAssertEqual(m.config.endpoints.count, 2)
    }

    func testDeleteEndpointRemovesKeyButNeverTheLegacyKey() throws {
        let (m, paths, _) = makeModel()
        try ConfigStore(paths: paths).save(sampleConfig())
        try KeyStore(paths: paths).create("key")
        m.reloadFiles()
        let extra = Endpoint(id: "lap", name: "Laptop", port: 10201, keyFile: "keys/lap.key",
                             aliases: [AliasMapping(alias: "fast", model: "m/two")])
        XCTAssertTrue(m.addEndpoint(extra))
        XCTAssertTrue(m.deleteEndpoint("lap"))
        XCTAssertFalse(m.keys.exists("keys/lap.key"))
        XCTAssertTrue(m.deleteEndpoint("default"))
        XCTAssertTrue(m.keys.exists("key"))
    }

    func testRotateKey() throws {
        let (m, paths, _) = makeModel()
        try ConfigStore(paths: paths).save(sampleConfig())
        let old = try KeyStore(paths: paths).create("key")
        m.reloadFiles()
        let new = m.rotateKey(endpoint: "default")
        XCTAssertNotNil(new)
        XCTAssertNotEqual(new, old)
        XCTAssertEqual(m.key(for: "default"), new)
    }

    func testRefreshBuildsSummary() async throws {
        let (m, paths, runner) = makeModel()
        try ConfigStore(paths: paths).save(sampleConfig())
        try KeyStore(paths: paths).create("key")
        runner.results = [CommandResult(status: 0, output: "\tstate = running\n\tpid = 7\n")]
        try """
        {"filterVersion":2,"pid":7,"configError":null,"endpoints":{"default":{"host":"0.0.0.0","port":10200,"state":"listening","error":null}}}
        """.write(to: paths.runtime, atomically: true, encoding: .utf8)
        await m.refresh()
        XCTAssertEqual(m.summary.overall, .ok, "\(m.summary)")
        XCTAssertEqual(m.lanIP, "192.0.2.10")
        XCTAssertEqual(m.baseURL(m.config.endpoints[0]), "http://192.0.2.10:10200/v1")
        XCTAssertEqual(m.ocxModels?.count, 2)
    }

    func testSaveDraftCreatesAndRemovesKeys() throws {
        let (m, paths, _) = makeModel()
        try ConfigStore(paths: paths).save(sampleConfig())
        try KeyStore(paths: paths).create("key")
        m.reloadFiles()
        var draft = m.config
        draft.endpoints.append(Endpoint(id: "lap", name: "Laptop", port: 10201, keyFile: "keys/lap.key",
                                        aliases: [AliasMapping(alias: "fast", model: "m/two")]))
        XCTAssertEqual(m.saveDraft(draft, expecting: m.fingerprint), .saved)
        XCTAssertTrue(m.keys.exists("keys/lap.key"))

        var removal = m.config
        removal.endpoints.removeAll { $0.id == "lap" }
        XCTAssertEqual(m.saveDraft(removal, expecting: m.fingerprint), .saved)
        XCTAssertFalse(m.keys.exists("keys/lap.key"))
    }

    func testSaveDraftRejectedLeavesNoKeys() throws {
        let (m, paths, _) = makeModel()
        try ConfigStore(paths: paths).save(sampleConfig())
        m.reloadFiles()
        var bad = m.config
        bad.endpoints.append(Endpoint(id: "lap", name: "Laptop", port: 10200, keyFile: "keys/lap.key",
                                      aliases: [AliasMapping(alias: "fast", model: "m/two")]))
        guard case .invalid = m.saveDraft(bad, expecting: m.fingerprint) else { return XCTFail() }
        XCTAssertFalse(m.keys.exists("keys/lap.key"))

        var ok = m.config
        ok.endpoints.append(Endpoint(id: "lap", name: "Laptop", port: 10201, keyFile: "keys/lap.key",
                                     aliases: [AliasMapping(alias: "fast", model: "m/two")]))
        let stale = m.fingerprint
        var ext = sampleConfig(); ext.endpoints[0].aliases[0].model = "external"
        try ConfigStore(paths: paths).save(ext)
        XCTAssertEqual(m.saveDraft(ok, expecting: stale), .conflict)
        XCTAssertFalse(m.keys.exists("keys/lap.key"))
    }
}
