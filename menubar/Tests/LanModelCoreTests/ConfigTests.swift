import XCTest
@testable import LanModelCore

final class ConfigTests: XCTestCase {
    // S-01
    func testDecodesV2() throws {
        let p = makeTempPaths()
        let text = """
        {"version":2,"upstream":{"host":"127.0.0.1","port":10100},"endpoints":[
         {"id":"a","name":"A","enabled":true,"host":"0.0.0.0","port":10200,"keyFile":"key",
          "aliases":[{"alias":"x","model":"m"}]}],"upstream_model":"m"}
        """
        try text.write(to: p.config, atomically: true, encoding: .utf8)
        let l = try ConfigStore(paths: p).load()
        XCTAssertFalse(l.wasV1)
        XCTAssertEqual(l.config.endpoints[0].aliases[0].contextLength, 1_000_000)
        XCTAssertEqual(l.config.upstreamModelMirror, "m")
    }

    func testMigratesV1() throws {
        let p = makeTempPaths()
        try #"{"upstream_model": "provider/x"}"#.write(to: p.config, atomically: true, encoding: .utf8)
        let l = try ConfigStore(paths: p).load()
        XCTAssertTrue(l.wasV1)
        let ep = l.config.endpoints[0]
        XCTAssertEqual([ep.id, ep.keyFile, ep.aliases[0].alias, ep.aliases[0].model],
                       ["default", "key", "local-llm", "provider/x"])
        XCTAssertEqual(ep.port, 10200)
        XCTAssertTrue(ConfigValidator.validate(l.config).isEmpty)
    }

    func testMissingFileGivesDefaults() throws {
        let l = try ConfigStore(paths: makeTempPaths()).load()
        XCTAssertEqual(l.fingerprint, "missing")
        XCTAssertEqual(l.config.endpoints.count, 1)
    }

    func testBrokenJSONThrows() throws {
        let p = makeTempPaths()
        try "{ nope".write(to: p.config, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ConfigStore(paths: p).load())
    }

    func testRoundTripLosesNothing() throws {
        let p = makeTempPaths()
        var cfg = sampleConfig()
        cfg.endpoints.append(Endpoint(id: "b", name: "B", enabled: false, host: "127.0.0.1", port: 10201,
                                      keyFile: "keys/b.key",
                                      aliases: [AliasMapping(alias: "fast", model: "m/two", contextLength: 8000),
                                                AliasMapping(alias: "slow", model: "m/three")]))
        let store = ConfigStore(paths: p)
        try store.save(cfg)
        var back = try store.load().config
        back.upstreamModelMirror = nil
        XCTAssertEqual(back, cfg)
    }

    // S-02
    func testValidatorBoundaries() {
        func issues(_ edit: (inout ProxyConfig) -> Void) -> [ValidationIssue] {
            var c = sampleConfig(); edit(&c); return ConfigValidator.validate(c)
        }
        XCTAssertTrue(issues { _ in }.isEmpty)
        XCTAssertFalse(issues { $0.endpoints[0].port = 1023 }.isEmpty)
        XCTAssertTrue(issues { $0.endpoints[0].port = 1024 }.isEmpty)
        XCTAssertTrue(issues { $0.endpoints[0].port = 65535 }.isEmpty)
        XCTAssertFalse(issues { $0.endpoints[0].port = 65536 }.isEmpty)
        XCTAssertFalse(issues { $0.endpoints[0].port = 10100 }.isEmpty)
        XCTAssertFalse(issues { $0.endpoints[0].host = "10.0.0.1" }.isEmpty)
        XCTAssertFalse(issues { $0.endpoints[0].id = "Bad" }.isEmpty)
        XCTAssertFalse(issues { $0.endpoints[0].name = "" }.isEmpty)
        XCTAssertFalse(issues { $0.endpoints[0].name = String(repeating: "a", count: 65) }.isEmpty)
        XCTAssertFalse(issues { $0.endpoints[0].keyFile = "../x" }.isEmpty)
        XCTAssertFalse(issues { $0.endpoints[0].keyFile = "/abs" }.isEmpty)
        XCTAssertFalse(issues { $0.endpoints[0].keyFile = "a/../../b" }.isEmpty)
        XCTAssertTrue(issues { $0.endpoints[0].keyFile = "keys/a.key" }.isEmpty)
        XCTAssertFalse(issues { $0.endpoints[0].aliases = [] }.isEmpty)
        XCTAssertFalse(issues { $0.endpoints[0].aliases[0].alias = "has space" }.isEmpty)
        XCTAssertFalse(issues { $0.endpoints[0].aliases[0].model = "   " }.isEmpty)
        XCTAssertFalse(issues { $0.endpoints[0].aliases[0].contextLength = 0 }.isEmpty)
        XCTAssertFalse(issues { $0.endpoints[0].aliases[0].contextLength = 10_000_001 }.isEmpty)
        XCTAssertFalse(issues {
            $0.endpoints[0].aliases.append(AliasMapping(alias: "local-llm", model: "other"))
        }.isEmpty)
    }

    func testDuplicatePortsCountDisabledEndpoints() {
        var c = sampleConfig()
        c.endpoints.append(Endpoint(id: "b", name: "B", enabled: false, port: 10200, keyFile: "k2",
                                    aliases: [AliasMapping(alias: "x", model: "m")]))
        XCTAssertTrue(ConfigValidator.validate(c).contains { $0.message == "duplicate port" })
    }

    // S-03: the same fixtures drive tests/test_config.py
    func testSharedFixturesAgreeWithPython() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tests/fixtures/validation.json")
        let cases = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[String: Any]]
        XCTAssertGreaterThan(cases.count, 20)
        for c in cases {
            let name = c["name"] as! String
            let expectValid = c["valid"] as! Bool
            let data = try JSONSerialization.data(withJSONObject: c["config"]!)
            let valid: Bool
            if let cfg = try? JSONDecoder().decode(ProxyConfig.self, from: data) {
                valid = ConfigValidator.validate(cfg).isEmpty
            } else {
                valid = false  // wrong types fail to decode, which is also a rejection
            }
            XCTAssertEqual(valid, expectValid, "fixture '\(name)'")
        }
    }

    // S-04
    func testSaveIsAtomicBacksUpV1OnceAndMirrors() throws {
        let p = makeTempPaths()
        let original = #"{"upstream_model": "old/model"}"#
        try original.write(to: p.config, atomically: true, encoding: .utf8)
        let store = ConfigStore(paths: p)
        var cfg = try store.load().config
        cfg.endpoints[0].aliases[0].model = " new/model "
        try store.save(cfg)
        XCTAssertEqual(try String(contentsOf: p.configBackupV1), original)
        XCTAssertEqual(try store.load().config.endpoints[0].aliases[0].model, "new/model")
        XCTAssertEqual(try store.load().config.upstreamModelMirror, "new/model")
        cfg.endpoints[0].aliases[0].model = "newer"
        try store.save(cfg)
        XCTAssertEqual(try String(contentsOf: p.configBackupV1), original, "backup must not be overwritten by v2 saves")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: p.root.path).filter { $0.contains(".tmp") }
        XCTAssertEqual(leftovers, [])
    }

    func testInvalidConfigIsNeverWritten() throws {
        let p = makeTempPaths()
        let store = ConfigStore(paths: p)
        try store.save(sampleConfig())
        let before = try Data(contentsOf: p.config)
        var bad = sampleConfig()
        bad.endpoints[0].port = 80
        XCTAssertThrowsError(try store.save(bad)) {
            guard case ConfigStoreError.invalid = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try Data(contentsOf: p.config), before)
    }

    // S-05
    func testConflictDetection() throws {
        let p = makeTempPaths()
        let store = ConfigStore(paths: p)
        try store.save(sampleConfig())
        let loaded = try store.load()
        try #"{"upstream_model":"external"}"#.write(to: p.config, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try store.save(loaded.config, expecting: loaded.fingerprint)) {
            XCTAssertEqual($0 as? ConfigStoreError, .conflict)
        }
        XCTAssertNoThrow(try store.save(loaded.config, expecting: store.currentFingerprint()))
    }

    func testHelpers() {
        var c = sampleConfig()
        XCTAssertEqual(ConfigValidator.nextFreePort(in: c), 10201)
        XCTAssertEqual(ConfigValidator.nextFreeID(in: c, base: "default"), "default-2")
        XCTAssertEqual(ConfigValidator.nextFreeID(in: c), "endpoint")
        c.upstream.port = 10201
        XCTAssertEqual(ConfigValidator.nextFreePort(in: c), 10202)
    }
}
