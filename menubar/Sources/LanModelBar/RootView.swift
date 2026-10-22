import LanModelCore
import SwiftUI

/// The single window of the app. Every screen, picker and confirmation lives inside it:
/// no sheets, popovers, alerts, menus or extra windows (each of those would steal focus and close the menu bar window).
struct RootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var ui: UIState

    static let width: CGFloat = 400
    static let height: CGFloat = 540

    var body: some View {
        Group {
            switch ui.screen {
            case .list: ListScreen(model: model, ui: ui)
            case .form: FormScreen(model: model, ui: ui)
            case .picker(let t): PickerScreen(model: model, ui: ui, target: t)
            }
        }
        .frame(width: Self.width, height: Self.height)
        .clipped()
        .disabled(ui.pending != nil)
        .overlay(alignment: .bottom) {
            if let p = ui.pending { ConfirmBar(model: model, ui: ui, pending: p) }
        }
        .onExitCommand { if ui.screen != .list || ui.pending != nil { ui.back() } }
        .onChange(of: model.fingerprint) { _, _ in ui.syncIfClean() }
    }
}

struct ScreenHeader<Trailing: View>: View {
    let title: String
    let backLabel: String
    let back: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        ZStack {
            Text(title).font(.headline).lineLimit(1).truncationMode(.middle)
                .padding(.horizontal, 92)
                .accessibilityAddTraits(.isHeader)
            HStack {
                Button(action: back) {
                    Label(backLabel, systemImage: "chevron.left").labelStyle(.titleAndIcon)
                }
                .glassButton()
                .keyboardShortcut("[", modifiers: .command)
                Spacer()
                trailing
            }
        }
        .padding(.horizontal, Theme.edge).padding(.top, 14).padding(.bottom, 12)
    }
}

struct ConfirmBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var ui: UIState
    let pending: Pending

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(cancelLabel) { cancel() }.glassButton()
                Button(actionLabel, role: destructive ? .destructive : nil) { act() }
                    .glassButton(prominent: true).tint(destructive ? .red : .accentColor)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(10)
        .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message)
    }

    private var name: String { ui.endpoint?.name ?? "" }

    private var message: String {
        switch pending {
        case .discard: return "Отменить несохранённые изменения?"
        case .delete: return "Удалить эндпоинт «\(name)»? Его ключ будет удалён, клиенты потеряют доступ."
        case .rotate: return "Старый ключ перестанет работать сразу. Клиентов придётся перенастроить."
        case .conflict: return "Пока форма была открыта, config.json изменили снаружи (например, командой lanmodel)."
        case .restart: return "Перезапуск ненадолго оборвёт текущие запросы."
        }
    }

    private var cancelLabel: String {
        switch pending {
        case .discard: return "Продолжить правку"
        case .conflict: return "Перечитать"
        default: return S.cancel
        }
    }

    private var actionLabel: String {
        switch pending {
        case .discard: return "Отменить изменения"
        case .delete: return S.delete
        case .rotate: return "Сменить ключ"
        case .conflict: return S.overwrite
        case .restart: return "Перезапустить"
        }
    }

    private var destructive: Bool { pending != .restart }

    private func cancel() {
        if pending == .conflict { ui.reloadFromDisk() } else { ui.pending = nil }
    }

    private func act() {
        switch pending {
        case .discard: ui.closeEditor()
        case .delete: ui.deleteEndpoint()
        case .rotate: ui.rotateKey()
        case .conflict: ui.save(force: true)
        case .restart:
            ui.pending = nil
            Task { await model.restartService() }
        }
    }
}
