import Foundation

public enum OverallStatus: Equatable, Sendable {
    case ok, warning, down, paused
}

public enum Warning: Equatable, Hashable, Sendable {
    case serviceNotInstalled
    case serviceStopped
    case serviceOutdated(Int)
    case runtimeMissing
    case ocxUnreachable
    case configInvalid(String)
    case endpointError(id: String, message: String)
    case modelMissing(endpoint: String, alias: String, model: String)
    case keyMissing(endpoint: String)
}

public struct StatusInputs: Sendable {
    public var service: ServiceState
    public var runtime: RuntimeReadResult
    public var config: ProxyConfig
    public var ocxModels: [OCXModel]?   // nil = ocx unreachable
    public var loadError: String?
    public var missingKeys: Set<String>

    public init(service: ServiceState, runtime: RuntimeReadResult, config: ProxyConfig,
                ocxModels: [OCXModel]?, loadError: String? = nil, missingKeys: Set<String> = []) {
        self.service = service
        self.runtime = runtime
        self.config = config
        self.ocxModels = ocxModels
        self.loadError = loadError
        self.missingKeys = missingKeys
    }
}

public struct StatusSummary: Equatable, Sendable {
    public var overall: OverallStatus
    public var warnings: [Warning]

    public static func compute(_ i: StatusInputs) -> StatusSummary {
        var warnings: [Warning] = []
        var down = false

        switch i.service {
        case .notInstalled: warnings.append(.serviceNotInstalled); down = true
        case .stopped: warnings.append(.serviceStopped); down = true
        case .running: break
        }
        if let e = i.loadError { warnings.append(.configInvalid(e)) }

        let enabled = i.config.endpoints.filter(\.enabled)
        switch i.runtime {
        case .ok(let rt):
            if let e = rt.configError { warnings.append(.configInvalid(e)) }
            if case .running = i.service {
                for ep in enabled {
                    if let r = rt.endpoints[ep.id] {
                        if r.state == .error { warnings.append(.endpointError(id: ep.id, message: r.error ?? "error")) }
                        else if r.state != .listening { warnings.append(.endpointError(id: ep.id, message: "not listening yet")) }
                    }
                }
            }
        case .outdated(let v): warnings.append(.serviceOutdated(v))
        case .missing, .unreadable:
            if case .running = i.service { warnings.append(.runtimeMissing) }
        }

        if let models = i.ocxModels {
            let ids = Set(models.map(\.id))
            for ep in enabled {
                for a in ep.aliases where !ids.contains(a.model) {
                    warnings.append(.modelMissing(endpoint: ep.id, alias: a.alias, model: a.model))
                }
            }
        } else {
            warnings.append(.ocxUnreachable)
            down = true
        }
        for ep in enabled where i.missingKeys.contains(ep.id) { warnings.append(.keyMissing(endpoint: ep.id)) }

        let overall: OverallStatus
        if down { overall = .down }
        else if enabled.isEmpty { overall = .paused }
        else if warnings.isEmpty { overall = .ok }
        else { overall = .warning }
        return StatusSummary(overall: overall, warnings: warnings)
    }
}
