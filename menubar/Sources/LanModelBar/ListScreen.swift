import AppKit
import LanModelCore
import SwiftUI

struct ListScreen: View {
    @ObservedObject var model: AppModel
    @ObservedObject var ui: UIState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            banners
            if model.config.endpoints.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(model.config.endpoints) { ep in
                            EndpointCard(model: model, ui: ui, endpoint: ep)
                        }
                    }
                    .padding(.horizontal, Theme.edge).padding(.bottom, 8)
                }
                .softScrollEdges()
                .frame(maxHeight: .infinity)
            }
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(model.summary.overall.color.opacity(0.18)).frame(width: 40, height: 40)
                Image(systemName: model.summary.overall.symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(model.summary.overall.color)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(S.overallLabel(model.summary.overall)).font(.title3.weight(.semibold))
                Text(ocxLine).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.busy { ProgressView().controlSize(.small) }
            GlassIconButton(symbol: "plus", label: S.newEndpoint) { ui.startNew() }
                .keyboardShortcut("n", modifiers: .command)
        }
        .padding(.horizontal, Theme.edge).padding(.top, 14).padding(.bottom, 12)
    }

    private var ocxLine: String {
        let base = "ocx \(model.config.upstream.host):\(model.config.upstream.port)"
        guard let n = model.ocxModels?.count else { return base + tr(" · недоступен", " · unavailable") }
        return base + tr(" · моделей: \(n)", " · models: \(n)")
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "network").font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
            Text(tr("Нет эндпоинтов", "No endpoints")).font(.headline)
            Button(tr("Создать эндпоинт", "Create endpoint")) { ui.startNew() }.glassButton(prominent: true).controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var banners: some View {
        let generic = model.summary.warnings.filter { w in
            if case .modelMissing = w { return false }
            return true
        }
        if !generic.isEmpty || model.lastError != nil {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(generic.enumerated()), id: \.offset) { _, w in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(S.warning(w)).font(.callout).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        action(for: w)
                    }
                }
                if let e = model.lastError {
                    Label(e, systemImage: "xmark.octagon.fill").font(.callout).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, Theme.edge).padding(.bottom, 10)
        }
    }

    @ViewBuilder private func action(for w: Warning) -> some View {
        switch w {
        case .serviceNotInstalled:
            Button(S.install) { Task { await model.installService() } }.glassButton().controlSize(.small)
        case .serviceOutdated:
            Button(S.update) { Task { await model.installService() } }.glassButton().controlSize(.small)
        case .serviceStopped:
            Button(S.start) { Task { await model.restartService() } }.glassButton().controlSize(.small)
        case .configInvalid:
            Button(S.openFile) { NSWorkspace.shared.activateFileViewerSelecting([model.deps.paths.config]) }
                .glassButton().controlSize(.small)
        default: EmptyView()
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button { ui.screen = .settings } label: { Label(S.settings, systemImage: "gearshape") }
                .glassButton().controlSize(.regular)
                .keyboardShortcut(",")
            Spacer()
            HStack(spacing: 8) {
                GlassIconButton(symbol: "arrow.clockwise", label: S.restartService, size: 30) { ui.pending = .restart }
                    .disabled(model.busy)
                GlassIconButton(symbol: "doc.text", label: S.openLog, size: 30) { NSWorkspace.shared.open(model.deps.paths.log) }
                GlassIconButton(symbol: "power", label: S.quit, size: 30) { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .glassContainer()
        }
        .padding(.horizontal, Theme.edge).padding(.vertical, 12)
    }
}

struct ModelPill: View {
    let model: String
    let known: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if !known {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                Text(model.isEmpty ? tr("Выбрать модель", "Choose a model") : model)
                    .font(.footnote).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassSurface(Capsule(), tint: known ? nil : .orange.opacity(0.25), interactive: true)
        .help(known ? tr("Выбрать модель", "Choose a model") : tr("Этой модели нет в каталоге ocx", "This model is not in the ocx catalog"))
        .accessibilityHint(tr("Открыть выбор модели", "Open the model picker"))
    }
}

struct EndpointCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var ui: UIState
    let endpoint: Endpoint
    @State private var copiedKey = false

    private var runtimeEntry: EndpointRuntime? {
        if case .ok(let rt) = model.runtime { return rt.endpoints[endpoint.id] }
        return nil
    }

    private var runtimeError: String? {
        guard let e = runtimeEntry, e.state == .error else { return nil }
        return e.error ?? tr("ошибка", "error")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StatusDot(state: runtimeEntry?.state, enabled: endpoint.enabled)
                Text(endpoint.name).font(.headline).lineLimit(1)
                if endpoint.scope == .localOnly {
                    Text(tr("этот Mac", "this Mac")).font(.caption2.weight(.medium)).padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.primary.opacity(0.10), in: Capsule())
                }
                Spacer()
                Toggle(tr("Включён", "Enabled"), isOn: Binding(
                    get: { endpoint.enabled },
                    set: { _ = model.setEnabled(endpoint: endpoint.id, $0) }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .accessibilityLabel(tr("Эндпоинт \(endpoint.name) включён", "Endpoint \(endpoint.name) enabled"))
            }
            Text(model.baseURL(endpoint)).font(.caption.monospaced()).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            if let e = runtimeError { Text(e).font(.caption).foregroundStyle(.red) }
            if endpoint.enabled {
                VStack(spacing: 6) {
                    ForEach(endpoint.aliases) { a in
                        HStack(spacing: 8) {
                            Text(a.alias).font(.callout.monospaced().weight(.medium))
                                .lineLimit(1).frame(width: 78, alignment: .leading)
                            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
                            ModelPill(model: a.model, known: model.ocxModels?.contains { $0.id == a.model } ?? true) {
                                ui.openPicker(PickerTarget(endpointID: endpoint.id, alias: a.alias, draftIndex: nil, current: a.model))
                            }
                        }
                    }
                }
                .glassContainer()
                probeLine
                actions
            }
        }
        .padding(14)
        .card()
        .opacity(endpoint.enabled ? 1 : 0.55)
        .accessibilityElement(children: .contain)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                GlassIconButton(symbol: "doc.on.doc", label: tr("Скопировать URL", "Copy URL"), size: 28) { Clipboard.copy(model.baseURL(endpoint)) }
                GlassIconButton(symbol: "terminal", label: tr("Скопировать curl", "Copy curl"), size: 28) {
                    Clipboard.copy(NetworkInfo.curlExample(for: endpoint, lanIP: model.lanIP))
                }
                GlassIconButton(symbol: copiedKey ? "checkmark" : "key",
                                label: copiedKey ? tr("Скопировано", "Copied") : tr("Скопировать ключ (очистится через 60 с)", "Copy key (clipboard clears after 60 s)"),
                                size: 28, tint: copiedKey ? .green.opacity(0.35) : nil) {
                    if let k = model.key(for: endpoint.id) {
                        Clipboard.copySecret(k.value)
                        copiedKey = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedKey = false }
                    }
                }
                GlassIconButton(symbol: "checkmark.seal", label: S.probe, size: 28) {
                    Task { await model.runProbe(endpoint: endpoint.id) }
                }
                .disabled(model.probes[endpoint.id] == .running)
            }
            .glassContainer()
            Spacer()
            Button(S.edit) { ui.edit(endpoint.id) }.glassButton().controlSize(.regular)
        }
    }

    @ViewBuilder private var probeLine: some View {
        switch model.probes[endpoint.id] ?? .idle {
        case .idle: EmptyView()
        case .running:
            HStack { ProgressView().controlSize(.small); Text(tr("Проверяю…", "Testing…")).font(.caption) }
        case .done(.ok(let m, let answer, let secs)):
            Label(tr("ок за \(String(format: "%.1f", secs)) с · ответила \(m) · «\(answer)»", "ok in \(String(format: "%.1f", secs)) s · answered by \(m) · “\(answer)”"), systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green).lineLimit(2)
        case .done(.failed(let msg)):
            Label(msg, systemImage: "xmark.circle.fill").font(.caption).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
