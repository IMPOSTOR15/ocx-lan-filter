import Foundation
import LanModelCore
import ServiceManagement

struct PickerTarget: Equatable {
    var endpointID: String
    var alias: String
    /// Index into the draft's aliases when picking from the form; nil when changing a live alias from the list.
    var draftIndex: Int?
    var current: String
}

enum Pending: Equatable {
    case discard, delete, rotate, conflict, restart
}

/// All navigation and editor-draft state lives here (not in views), so closing the popover loses nothing.
@MainActor
final class UIState: ObservableObject {
    enum Screen: Equatable {
        case list, form
        case picker(PickerTarget)
    }

    let model: AppModel
    @Published var screen: Screen = .list
    @Published var launchAtLogin: Bool

    @Published private(set) var draft = ProxyConfig()
    @Published private(set) var editingID = ""
    @Published private(set) var isNew = false
    @Published private(set) var dirty = false
    @Published private(set) var issues: [ValidationIssue] = []
    @Published var saveError: String?
    @Published var pending: Pending?
    @Published private(set) var revealed: String?
    private(set) var baseFingerprint = "missing"
    private var hideTask: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("launch at login failed: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: navigation

    func back() {
        if pending != nil { pending = nil; return }
        switch screen {
        case .list: break
        case .picker(let t): screen = t.draftIndex == nil ? .list : .form
        case .form: requestClose()
        }
    }

    func openPicker(_ target: PickerTarget) { screen = .picker(target) }

    func requestClose() {
        if dirty { pending = .discard } else { closeEditor() }
    }

    func closeEditor() {
        pending = nil
        hideKey()
        resetDraft()
        screen = .list
    }

    // MARK: draft

    var index: Int? { draft.endpoints.firstIndex { $0.id == editingID } }
    var endpoint: Endpoint? { index.map { draft.endpoints[$0] } }

    func edit(_ id: String) {
        resetDraft()
        editingID = id
        isNew = false
        screen = .form
    }

    func startNew() {
        resetDraft()
        let id = ConfigValidator.nextFreeID(in: draft)
        let seed = draft.endpoints.first?.aliases.first?.model ?? model.ocxModels?.first?.id ?? ""
        draft.endpoints.append(Endpoint(
            id: id, name: "Новый эндпоинт", host: ListenScope.lan.rawValue,
            port: ConfigValidator.nextFreePort(in: draft),
            keyFile: KeyStore.defaultKeyFile(forEndpoint: id),
            aliases: [AliasMapping(alias: "local-llm", model: seed)]))
        editingID = id
        isNew = true
        touch()
        screen = .form
    }

    func resetDraft() {
        model.reloadFiles()
        draft = model.config
        baseFingerprint = model.fingerprint
        dirty = false
        issues = []
        saveError = nil
        pending = nil
        hideKey()
    }

    /// Called when the config changes on disk while the form is open and untouched.
    func syncIfClean() {
        guard screen == .form, !dirty, model.fingerprint != baseFingerprint else { return }
        reloadFromDisk()
    }

    func touch() {
        dirty = true
        saveError = nil
        issues = ConfigValidator.validate(draft)
    }

    func set<T>(_ kp: WritableKeyPath<Endpoint, T>, _ value: T) {
        guard let i = index else { return }
        draft.endpoints[i][keyPath: kp] = value
        touch()
    }

    func setAlias<T>(_ j: Int, _ kp: WritableKeyPath<AliasMapping, T>, _ value: T) {
        guard let i = index, draft.endpoints[i].aliases.indices.contains(j) else { return }
        draft.endpoints[i].aliases[j][keyPath: kp] = value
        touch()
    }

    func addAlias() {
        guard let i = index else { return }
        var n = draft.endpoints[i].aliases.count + 1
        var name = "alias-\(n)"
        while draft.endpoints[i].aliases.contains(where: { $0.alias == name }) { n += 1; name = "alias-\(n)" }
        draft.endpoints[i].aliases.append(AliasMapping(alias: name, model: draft.endpoints[i].aliases.last?.model ?? ""))
        touch()
    }

    func removeAlias(_ j: Int) {
        guard let i = index, draft.endpoints[i].aliases.count > 1,
              draft.endpoints[i].aliases.indices.contains(j) else { return }
        draft.endpoints[i].aliases.remove(at: j)
        touch()
    }

    func issue(_ path: String) -> String? {
        issues.first { $0.path == path }.map { S.validationHint($0.message) }
    }

    func choose(_ id: String, for target: PickerTarget) {
        let id = id.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return }
        if let j = target.draftIndex {
            setAlias(j, \.model, id)
            screen = .form
        } else {
            _ = model.setModel(endpoint: target.endpointID, alias: target.alias, model: id)
            screen = .list
        }
    }

    var portOrScopeChanged: Bool {
        guard let ep = endpoint, let old = model.config.endpoint(ep.id) else { return false }
        return old.port != ep.port || old.host != ep.host
    }

    // MARK: save / delete

    func save(force: Bool = false) {
        pending = nil
        switch model.saveDraft(draft, expecting: force ? nil : baseFingerprint) {
        case .saved: closeEditor()
        case .conflict: pending = .conflict
        case .invalid(let i): issues = i
        case .failed(let m): saveError = m
        }
    }

    func deleteEndpoint() {
        pending = nil
        guard let i = index else { return }
        if isNew { closeEditor(); return }
        let backup = draft
        draft.endpoints.remove(at: i)
        save()
        if screen == .form { draft = backup }
    }

    func reloadFromDisk() {
        let id = editingID
        resetDraft()
        editingID = id
        if index == nil { closeEditor() }
    }

    // MARK: key

    var keyExists: Bool { endpoint.map { !isNew && model.keys.exists($0.keyFile) } ?? false }

    func toggleReveal() {
        if revealed != nil { hideKey(); return }
        guard let ep = endpoint, let k = model.key(for: ep.id) else { return }
        revealed = k.value
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            if !Task.isCancelled { self?.revealed = nil }
        }
    }

    func hideKey() {
        hideTask?.cancel()
        revealed = nil
    }

    func rotateKey() {
        pending = nil
        guard let ep = endpoint, let k = model.rotateKey(endpoint: ep.id) else { return }
        if revealed != nil { revealed = k.value }
    }
}
