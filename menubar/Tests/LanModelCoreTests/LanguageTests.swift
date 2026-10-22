import XCTest
@testable import LanModelCore

final class LanguageTests: XCTestCase {
    func testSystemRussianOnlyWhenPrimaryIsRussian() {
        XCTAssertEqual(LanguagePreference.system.resolve(preferred: ["ru-RU", "en-US"]), .ru)
        XCTAssertEqual(LanguagePreference.system.resolve(preferred: ["ru"]), .ru)
        XCTAssertEqual(LanguagePreference.system.resolve(preferred: ["RU-BY"]), .ru)
    }

    func testSystemFallsBackToEnglishEverywhereElse() {
        XCTAssertEqual(LanguagePreference.system.resolve(preferred: ["en-US", "ru-RU"]), .en)
        XCTAssertEqual(LanguagePreference.system.resolve(preferred: ["de-DE"]), .en)
        XCTAssertEqual(LanguagePreference.system.resolve(preferred: ["uk-UA"]), .en)
        XCTAssertEqual(LanguagePreference.system.resolve(preferred: ["ruthenian"]), .en)
        XCTAssertEqual(LanguagePreference.system.resolve(preferred: []), .en)
    }

    func testExplicitChoiceIgnoresSystem() {
        XCTAssertEqual(LanguagePreference.ru.resolve(preferred: ["en-US"]), .ru)
        XCTAssertEqual(LanguagePreference.en.resolve(preferred: ["ru-RU"]), .en)
    }

    func testStoredPreferenceRoundTripAndDefault() {
        let d = UserDefaults(suiteName: "lang-test-\(UUID().uuidString)")!
        XCTAssertEqual(LanguagePreference.stored(in: d), .system)
        LanguagePreference.en.store(in: d)
        XCTAssertEqual(LanguagePreference.stored(in: d), .en)
        d.set("klingon", forKey: LanguagePreference.defaultsKey)
        XCTAssertEqual(LanguagePreference.stored(in: d), .system)
    }
}
