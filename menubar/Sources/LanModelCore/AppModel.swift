import Combine
import Foundation

public enum ProbeState: Equatable, Sendable {
    case idle
    case running
    case done(ProbeResult)
}

public enum SaveOutcome: Equatable, Sendable {
    case saved
    case conflict
    case invalid([ValidationIssue])
    case failed(String)
}

public struct Dependencies: Sendable {
    public var paths: Paths
    public var service: ServiceController
    public var ocx: @Sendable (Upstream) -> OCXClient
    public var probe: EndpointProbe
    public var lanIP: @Sendable () -> String?
    public var installDirectory: URL?

    public init(paths: Paths = .standard(), service: ServiceController = ServiceController(),
                ocx: @escaping @Sendable (Upstream) -> OCXClient = { OCXClient(host: $0.host, port: $0.port) },
                probe: EndpointProbe = EndpointProbe(),
                lanIP: @escaping @Sendable () -> String? = { NetworkInfo.lanIPv4() },
                installDirectory: URL? = nil) {
        self.paths = paths
        self.service = service
        self.ocx = ocx
        self.probe = probe
        self.lanIP = lanIP
        self.installDirectory = installDirectory
    }
}

@MainActor
public final class AppModel: ObservableObject {
    @Published public private(set) var config: ProxyConfig
    @Published public private(set) var fingerprint: String = "missing"
    @Published public private(set) var loadError: String?
    @Published public private(set) var service: ServiceState = .notInstalled
    @Published public private(set) var runtime: RuntimeReadResult = .missing
    @Published public private(set) var ocxModels: [OCXModel]?
    @Published public private(set) var lanIP: String?
    @Published public private(set) var probes: [String: ProbeState] = [:]
    @Published public private(set) var summary = StatusSummary(overall: .down, warnings: [])
    @Published public private(set) var lastError: String?
    @Published public private(set) var busy = false

    public let deps: Dependencies
    public let store: ConfigStore
    public let keys: KeyStore
    private let runtimeReader: RuntimeStatusReader

    public init(deps: Dependencies = Dependencies()) {
        self.deps = deps
        self.store = ConfigStore(paths: deps.paths)
        self.keys = KeyStore(paths: deps.paths)
        self.runtimeReader = RuntimeStatusReader(paths: deps.paths)
        self.config = ProxyConfig.migratedFromV1(model: nil)
    }

    // MARK: refresh

    /// Re-reads config + runtime from disk without touching the network. Cheap, used on every tick.
    public func reloadFiles() {
        do {
            let loaded = try store.load()
            if loaded.fingerprint != fingerprint || loadError != nil {
                config = loaded.config
                fingerprint = loaded.fingerprint
            }
            loadError = nil
        } catch {
            loadError = "\(error)"
        }
        runtime = runtimeReader.read()
    }

    public func refresh() async {
        reloadFiles()
        service = await deps.service.state()
        lanIP = deps.lanIP()
        do { ocxModels = try await deps.ocx(config.upstream).models() } catch { ocxModels = nil }
        recomputeSummary()
    }

    func recomputeSummary() {
        let missing = Set(config.endpoints.filter { !keys.exists($0.keyFile) }.map(\.id))
        summary = StatusSummary.compute(StatusInputs(
            service: service, runtime: runtime, config: config, ocxModels: ocxModels,
            loadError: loadError, missingKeys: missing))
    }

    // MARK: editing

    /// Applies `change` to a copy of the config and saves it. On failure nothing is written and `lastError` is set.
    @discardableResult
    public func mutate(_ change: (inout ProxyConfig) -> Void) -> Bool {
        var next = config
        change(&next)
        return commit(next)
    }

    @discardableResult
    public func commit(_ next: ProxyConfig, expecting: String? = nil) -> Bool {
        do {
            fingerprint = try store.save(next, expecting: expecting)
            config = try store.load().config
            lastError = nil
            recomputeSummary()
            return true
        } catch {
            lastError = "\(error)"
            return false
        }
    }

    /// Saves an editor draft: creates keys for new endpoints first, drops keys of removed ones afterwards.
    /// Nothing is left behind if the save is rejected.
    public func saveDraft(_ draft: ProxyConfig, expecting fingerprint: String?) -> SaveOutcome {
        let issues = ConfigValidator.validate(draft)
        guard issues.isEmpty else { return .invalid(issues) }
        var created: [String] = []
        for ep in draft.endpoints where !keys.exists(ep.keyFile) {
            do { try keys.create(ep.keyFile); created.append(ep.keyFile) } catch {
                created.forEach(keys.remove)
                return .failed("\(error)")
            }
        }
        let previous = config
        do {
            self.fingerprint = try store.save(draft, expecting: fingerprint)
            config = try store.load().config
        } catch ConfigStoreError.conflict {
            created.forEach(keys.remove)
            return .conflict
        } catch ConfigStoreError.invalid(let i) {
            created.forEach(keys.remove)
            return .invalid(i)
        } catch {
            created.forEach(keys.remove)
            return .failed("\(error)")
        }
        let stillUsed = Set(draft.endpoints.map(\.keyFile))
        for gone in previous.endpoints where !draft.endpoints.contains(where: { $0.id == gone.id }) {
            if gone.keyFile != "key", !stillUsed.contains(gone.keyFile) { keys.remove(gone.keyFile) }
            probes[gone.id] = nil
        }
        lastError = nil
        recomputeSummary()
        return .saved
    }

    public func setModel(endpoint: String, alias: String, model: String) -> Bool {
        mutate { cfg in
            guard let i = cfg.endpoints.firstIndex(where: { $0.id == endpoint }),
                  let j = cfg.endpoints[i].aliases.firstIndex(where: { $0.alias == alias }) else { return }
            cfg.endpoints[i].aliases[j].model = model
        }
    }

    public func setEnabled(endpoint: String, _ enabled: Bool) -> Bool {
        mutate { cfg in
            if let i = cfg.endpoints.firstIndex(where: { $0.id == endpoint }) { cfg.endpoints[i].enabled = enabled }
        }
    }

    /// Creates the key first, so the filter never sees an enabled endpoint without one.
    public func addEndpoint(_ ep: Endpoint) -> Bool {
        var createdKey = false
        if !keys.exists(ep.keyFile) {
            do { try keys.create(ep.keyFile); createdKey = true } catch {
                lastError = "\(error)"
                return false
            }
        }
        let ok = mutate { $0.endpoints.append(ep) }
        if !ok, createdKey { keys.remove(ep.keyFile) }
        return ok
    }

    public func deleteEndpoint(_ id: String, removeKey: Bool = true) -> Bool {
        guard let ep = config.endpoint(id) else { return false }
        let ok = mutate { $0.endpoints.removeAll { $0.id == id } }
        if ok, removeKey, ep.keyFile != "key" { keys.remove(ep.keyFile) }
        probes[id] = nil
        return ok
    }

    public func rotateKey(endpoint id: String) -> SecretKey? {
        guard let ep = config.endpoint(id) else { return nil }
        do {
            let k = try keys.rotate(ep.keyFile)
            lastError = nil
            recomputeSummary()
            return k
        } catch {
            lastError = "\(error)"
            return nil
        }
    }

    public func key(for endpoint: String) -> SecretKey? {
        guard let ep = config.endpoint(endpoint) else { return nil }
        return try? keys.read(ep.keyFile)
    }

    // MARK: probe & service

    public func runProbe(endpoint id: String) async {
        guard let ep = config.endpoint(id), let alias = ep.aliases.first, let key = key(for: id) else {
            probes[id] = .done(.failed("no key file"))
            return
        }
        probes[id] = .running
        let result = await deps.probe.probe(port: ep.port, alias: alias.alias, key: key)
        probes[id] = .done(result)
    }

    public func restartService() async {
        busy = true
        let r = await deps.service.restart()
        lastError = r.status == 0 ? nil : "launchctl: \(r.output.trimmingCharacters(in: .whitespacesAndNewlines))"
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        busy = false
        await refresh()
    }

    public func stopService() async {
        busy = true
        _ = await deps.service.stop()
        busy = false
        await refresh()
    }

    public func installService() async {
        guard let dir = deps.installDirectory else {
            lastError = "install files are not bundled with this build"
            return
        }
        busy = true
        let r = await deps.service.install(scriptDirectory: dir)
        lastError = r.status == 0 ? nil : "install.sh failed: \(r.output.suffix(300))"
        busy = false
        await refresh()
    }

    public func baseURL(_ ep: Endpoint) -> String { NetworkInfo.baseURL(for: ep, lanIP: lanIP) }
}
