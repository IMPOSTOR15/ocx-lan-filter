import LanModelCore
import SwiftUI

struct FormScreen: View {
    @ObservedObject var model: AppModel
    @ObservedObject var ui: UIState

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: ui.isNew ? tr("Новый эндпоинт", "New endpoint") : tr("Изменить", "Edit"), backLabel: S.cancel, back: { ui.requestClose() }) {
                Button(S.save) { ui.save() }
                    .glassButton(prominent: true)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ui.dirty || !ui.issues.isEmpty)
            }
            if ui.endpoint != nil {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        general
                        network
                        keySection
                        aliases
                        connection
                        if !ui.isNew { danger }
                    }
                    .padding(.horizontal, Theme.edge).padding(.bottom, 12)
                }
                .softScrollEdges()
                .frame(maxHeight: .infinity)
            }
            statusLine
        }
    }

    private var i: Int { ui.index ?? 0 }

    private func error(_ path: String) -> some View {
        Group {
            if let t = ui.issue(path) {
                Text(t).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func bind<T>(_ kp: WritableKeyPath<Endpoint, T>) -> Binding<T> {
        Binding(get: { ui.endpoint![keyPath: kp] }, set: { ui.set(kp, $0) })
    }

    private func bindAlias<T>(_ j: Int, _ kp: WritableKeyPath<AliasMapping, T>) -> Binding<T> {
        Binding(get: { (ui.endpoint?.aliases[safe: j] ?? ui.endpoint!.aliases[0])[keyPath: kp] },
                set: { ui.setAlias(j, kp, $0) })
    }

    private var general: some View {
        FormCard(title: tr("Общее", "General")) {
            TextField(tr("Название", "Name"), text: bind(\.name)).textFieldStyle(.plain).inset()
            error("endpoints[\(i)].name")
            FormRow(label: tr("Включён", "Enabled")) {
                Toggle(tr("Включён", "Enabled"), isOn: bind(\.enabled)).toggleStyle(.switch).controlSize(.small).labelsHidden()
            }
            FormRow(label: "Id") {
                Text(ui.endpoint?.id ?? "").font(.callout.monospaced()).foregroundStyle(.secondary)
            }
            error("endpoints[\(i)].id")
        }
    }

    private var network: some View {
        FormCard(title: tr("Сеть", "Network")) {
            Picker(tr("Доступ", "Access"), selection: Binding(get: { ui.endpoint?.scope ?? .lan }, set: { ui.set(\.scope, $0) })) {
                Text(tr("Вся сеть", "Whole network")).tag(ListenScope.lan)
                Text(tr("Этот Mac", "This Mac")).tag(ListenScope.localOnly)
            }
            .pickerStyle(.segmented).labelsHidden()
            Text(ui.endpoint?.scope == .lan
                 ? tr("Слушает 0.0.0.0, доступен устройствам в локальной сети по ключу",
                      "Listens on 0.0.0.0, reachable from your local network with the key")
                 : tr("Слушает 127.0.0.1, доступен только на этом Mac",
                      "Listens on 127.0.0.1, reachable from this Mac only"))
                .font(.caption).foregroundStyle(.secondary)
            FormRow(label: tr("Порт", "Port")) {
                TextField(tr("Порт", "Port"), value: bind(\.port), format: .number.grouping(.never))
                    .textFieldStyle(.plain).multilineTextAlignment(.trailing).labelsHidden()
                    .inset().frame(width: 100)
            }
            error("endpoints[\(i)].port")
            if ui.portOrScopeChanged {
                Label(tr("Клиенты на старом адресе потеряют соединение", "Clients on the old address will lose the connection"), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var keySection: some View {
        FormCard(title: tr("Ключ доступа", "Access key")) {
            if ui.keyExists {
                Text(ui.revealed ?? "lan_••••••••••••••••").font(.callout.monospaced())
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).inset()
                HStack(spacing: 8) {
                    Button(ui.revealed == nil ? tr("Показать", "Show") : tr("Скрыть", "Hide")) { ui.toggleReveal() }.glassButton()
                    Button(tr("Копировать", "Copy")) {
                        if let id = ui.endpoint?.id, let k = model.key(for: id) { Clipboard.copySecret(k.value) }
                    }.glassButton()
                    Spacer()
                    Button(tr("Сменить…", "Rotate…")) { ui.pending = .rotate }.glassButton()
                }
                .controlSize(.small).glassContainer()
                if ui.revealed != nil {
                    Text(tr("Ключ скроется через 15 секунд", "The key hides again in 15 seconds")).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Label(tr("Будет создан при сохранении", "Will be created on save"), systemImage: "key").font(.callout).foregroundStyle(.secondary)
            }
            error("endpoints[\(i)].keyFile")
        }
    }

    private var aliases: some View {
        FormCard(title: tr("Алиасы", "Aliases")) {
            ForEach(Array((ui.endpoint?.aliases ?? []).enumerated()), id: \.offset) { j, a in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        TextField(tr("Алиас", "Alias"), text: bindAlias(j, \.alias))
                            .textFieldStyle(.plain).font(.callout.monospaced()).inset().frame(width: 124)
                        ModelPill(model: a.model, known: model.ocxModels?.contains { $0.id == a.model } ?? true) {
                            if let ep = ui.endpoint {
                                ui.openPicker(PickerTarget(endpointID: ep.id, alias: a.alias, draftIndex: j, current: a.model))
                            }
                        }
                        Button { ui.removeAlias(j) } label: {
                            Image(systemName: "minus.circle.fill").font(.title3).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain).help(tr("Удалить алиас", "Remove alias")).accessibilityLabel(tr("Удалить алиас \(a.alias)", "Remove alias \(a.alias)"))
                        .disabled((ui.endpoint?.aliases.count ?? 0) <= 1)
                    }
                    FormRow(label: tr("Контекст, токенов", "Context, tokens")) {
                        TextField(tr("Контекст", "Context"), value: bindAlias(j, \.contextLength), format: .number.grouping(.never))
                            .textFieldStyle(.plain).multilineTextAlignment(.trailing).labelsHidden()
                            .inset().frame(width: 110)
                            .help(tr("Контекст в токенах, который объявляется клиентам", "Context size in tokens advertised to clients"))
                    }
                    .font(.callout).foregroundStyle(.secondary)
                    ForEach(["alias", "model", "contextLength"], id: \.self) { f in
                        error("endpoints[\(i)].aliases[\(j)].\(f)")
                    }
                }
                if j < (ui.endpoint?.aliases.count ?? 0) - 1 { Divider() }
            }
            error("endpoints[\(i)].aliases")
            Button { ui.addAlias() } label: { Label(tr("Добавить алиас", "Add alias"), systemImage: "plus") }
                .glassButton().controlSize(.small)
        }
    }

    private var connection: some View {
        FormCard(title: tr("Подключение", "Connection")) {
            if let ep = ui.endpoint {
                let url = NetworkInfo.baseURL(for: ep, lanIP: model.lanIP)
                HStack(spacing: 8) {
                    Text(url).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).inset()
                    GlassIconButton(symbol: "doc.on.doc", label: tr("Скопировать URL", "Copy URL"), size: 28) { Clipboard.copy(url) }
                }
                Button(tr("Копировать curl", "Copy curl")) { Clipboard.copy(NetworkInfo.curlExample(for: ep, lanIP: model.lanIP)) }
                    .glassButton().controlSize(.small)
            }
        }
    }

    private var danger: some View {
        Button(role: .destructive) { ui.pending = .delete } label: {
            Label(tr("Удалить эндпоинт", "Delete endpoint"), systemImage: "trash").frame(maxWidth: .infinity)
        }
        .glassButton().controlSize(.large).tint(.red).foregroundStyle(.red)
    }

    @ViewBuilder private var statusLine: some View {
        HStack {
            if let e = ui.saveError {
                Label(e, systemImage: "xmark.octagon.fill").foregroundStyle(.red).lineLimit(2)
            } else if !ui.issues.isEmpty {
                Label(tr("Исправьте ошибки в форме", "Fix the errors in the form"), systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
            } else if ui.dirty {
                Label(tr("Есть несохранённые изменения", "Unsaved changes"), systemImage: "circle.fill").foregroundStyle(.secondary)
            } else {
                Text(" ")
            }
            Spacer()
        }
        .font(.caption).padding(.horizontal, 18).frame(height: 30)
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
