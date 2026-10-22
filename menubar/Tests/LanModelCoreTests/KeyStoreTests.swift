import XCTest
@testable import LanModelCore

final class KeyStoreTests: XCTestCase {
    // S-06
    func testGenerateFormatAndUniqueness() throws {
        let a = try KeyStore.generate(), b = try KeyStore.generate()
        XCTAssertTrue(a.hasPrefix("lan_"))
        XCTAssertGreaterThanOrEqual(a.count, 40)
        XCTAssertNotEqual(a, b)
        XCTAssertNil(a.range(of: #"[^A-Za-z0-9_\-]"#, options: .regularExpression))
    }

    func testCreatePermissions() throws {
        let p = makeTempPaths()
        let ks = KeyStore(paths: p)
        try ks.create("keys/a.key")
        func perm(_ u: URL) -> Int { (try! FileManager.default.attributesOfItem(atPath: u.path)[.posixPermissions] as! NSNumber).intValue }
        XCTAssertEqual(perm(p.keyURL("keys/a.key")), 0o600)
        XCTAssertEqual(perm(p.keysDir), 0o700)
        try ks.create("topkey")
        XCTAssertEqual(perm(p.keyURL("topkey")), 0o600)
        XCTAssertTrue(ks.exists("topkey"))
    }

    func testRotateChangesValueAndReadTrims() throws {
        let ks = KeyStore(paths: makeTempPaths())
        let k1 = try ks.create("keys/a.key")
        let k2 = try ks.rotate("keys/a.key")
        XCTAssertNotEqual(k1, k2)
        XCTAssertEqual(try ks.read("keys/a.key"), k2)
        try "lan_abc\n".write(to: ks.paths.keyURL("legacy"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try ks.read("legacy").value, "lan_abc")
    }

    func testRejectsTraversal() {
        let ks = KeyStore(paths: makeTempPaths())
        XCTAssertThrowsError(try ks.create("../evil"))
        XCTAssertThrowsError(try ks.read("/etc/passwd"))
        XCTAssertFalse(ks.exists("../x"))
    }

    func testSecretNeverPrintsItself() {
        let k = SecretKey("lan_supersecretvalue")
        for s in ["\(k)", String(describing: k), String(reflecting: k), "\(k.masked)"] {
            XCTAssertFalse(s.contains("supersecret"), s)
        }
        XCTAssertEqual(k.masked, "lan_••••••••")
    }

    func testRemove() throws {
        let ks = KeyStore(paths: makeTempPaths())
        try ks.create("keys/a.key")
        ks.remove("keys/a.key")
        XCTAssertFalse(ks.exists("keys/a.key"))
    }
}
