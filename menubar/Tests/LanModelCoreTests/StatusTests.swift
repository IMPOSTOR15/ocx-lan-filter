import XCTest
@testable import LanModelCore

final class StatusTests: XCTestCase {
    func runtime(_ state: EndpointState = .listening, error: String? = nil, configError: String? = nil) -> RuntimeReadResult {
        .ok(RuntimeStatus(filterVersion: 2, pid: 1, startedAt: nil, configMtime: nil, configError: configError,
                          endpoints: ["default": EndpointRuntime(host: "0.0.0.0", port: 10200, state: state, error: error)]))
    }
    let models = [OCXModel(id: "m/one", contextLength: nil)]

    func inputs(service: ServiceState = .running(pid: 1), runtime: RuntimeReadResult? = nil,
                config: ProxyConfig = sampleConfig(), models: [OCXModel]?? = nil, loadError: String? = nil,
                missingKeys: Set<String> = []) -> StatusInputs {
        StatusInputs(service: service, runtime: runtime ?? self.runtime(), config: config,
                     ocxModels: models ?? self.models, loadError: loadError, missingKeys: missingKeys)
    }

    // S-13
    func testAllGood() {
        let s = StatusSummary.compute(inputs())
        XCTAssertEqual(s.overall, .ok)
        XCTAssertEqual(s.warnings, [])
    }

    func testServiceStates() {
        XCTAssertEqual(StatusSummary.compute(inputs(service: .notInstalled)).overall, .down)
        XCTAssertTrue(StatusSummary.compute(inputs(service: .notInstalled)).warnings.contains(.serviceNotInstalled))
        XCTAssertEqual(StatusSummary.compute(inputs(service: .stopped)).overall, .down)
        XCTAssertTrue(StatusSummary.compute(inputs(service: .stopped)).warnings.contains(.serviceStopped))
    }

    func testOCXUnreachableIsDown() {
        let s = StatusSummary.compute(inputs(models: .some(nil)))
        XCTAssertEqual(s.overall, .down)
        XCTAssertTrue(s.warnings.contains(.ocxUnreachable))
    }

    func testMissingModelIsWarning() {
        let s = StatusSummary.compute(inputs(models: .some([OCXModel(id: "other", contextLength: nil)])))
        XCTAssertEqual(s.overall, .warning)
        XCTAssertEqual(s.warnings, [.modelMissing(endpoint: "default", alias: "local-llm", model: "m/one")])
    }

    func testEndpointErrorIsWarning() {
        let s = StatusSummary.compute(inputs(runtime: runtime(.error, error: "address already in use")))
        XCTAssertEqual(s.overall, .warning)
        XCTAssertEqual(s.warnings, [.endpointError(id: "default", message: "address already in use")])
    }

    func testConfigErrorFromFilterAndFromDisk() {
        XCTAssertEqual(StatusSummary.compute(inputs(runtime: runtime(configError: "bad"))).overall, .warning)
        XCTAssertEqual(StatusSummary.compute(inputs(loadError: "bad json")).overall, .warning)
    }

    func testOutdatedAndMissingRuntime() {
        let o = StatusSummary.compute(inputs(runtime: .outdated(1)))
        XCTAssertEqual(o.overall, .warning)
        XCTAssertTrue(o.warnings.contains(.serviceOutdated(1)))
        XCTAssertTrue(StatusSummary.compute(inputs(runtime: .missing)).warnings.contains(.runtimeMissing))
    }

    func testAllDisabledIsPaused() {
        var c = sampleConfig(); c.endpoints[0].enabled = false
        XCTAssertEqual(StatusSummary.compute(inputs(runtime: runtime(.disabled), config: c)).overall, .paused)
    }

    func testDisabledEndpointsAreNotChecked() {
        var c = sampleConfig()
        c.endpoints.append(Endpoint(id: "off", name: "off", enabled: false, port: 10300, keyFile: "k",
                                    aliases: [AliasMapping(alias: "a", model: "does/not-exist")]))
        XCTAssertEqual(StatusSummary.compute(inputs(config: c)).overall, .ok)
    }

    func testMissingKey() {
        let s = StatusSummary.compute(inputs(missingKeys: ["default"]))
        XCTAssertEqual(s.overall, .warning)
        XCTAssertEqual(s.warnings, [.keyMissing(endpoint: "default")])
    }
}
