import LanModelCore
import SwiftUI

struct SettingsScreen: View {
    @ObservedObject var model: AppModel
    @ObservedObject var ui: UIState

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: S.settings, backLabel: S.back, back: { ui.back() }) {
                Color.clear.frame(width: 1, height: 1)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    language
                    general
                    about
                }
                .padding(.horizontal, Theme.edge).padding(.bottom, 12)
            }
            .softScrollEdges()
            .frame(maxHeight: .infinity)
        }
    }

    private var language: some View {
        FormCard(title: tr("Язык", "Language")) {
            Picker(tr("Язык", "Language"), selection: Binding(get: { ui.languagePreference }, set: { ui.setLanguage($0) })) {
                Text(tr("Как в системе", "System")).tag(LanguagePreference.system)
                Text("Русский").tag(LanguagePreference.ru)
                Text("English").tag(LanguagePreference.en)
            }
            .pickerStyle(.segmented).labelsHidden()
            if ui.languagePreference == .system {
                Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var hint: String {
        return tr("Сейчас: \(LanguagePreference.system.resolve() == .ru ? "русский" : "английский"). Русский выбирается, только если он основной язык системы, в остальных случаях английский.",
                  "Currently: \(LanguagePreference.system.resolve() == .ru ? "Russian" : "English"). Russian is used only when it is the primary system language; otherwise English.")
    }

    private var general: some View {
        FormCard(title: tr("Основные", "General")) {
            FormRow(label: S.launchAtLogin) {
                Toggle(S.launchAtLogin, isOn: Binding(get: { ui.launchAtLogin }, set: { ui.setLaunchAtLogin($0) }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
            }
        }
    }

    private var about: some View {
        FormCard(title: tr("О приложении", "About")) {
            FormRow(label: S.appName) {
                Text(version).font(.callout.monospaced()).foregroundStyle(.secondary)
            }
            Text(tr("Закрытие приложения не останавливает прокси: он работает как фоновый сервис.",
                    "Quitting the app does not stop the proxy: it runs as a background service."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
