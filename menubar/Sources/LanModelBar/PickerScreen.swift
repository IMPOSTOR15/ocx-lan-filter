import LanModelCore
import SwiftUI

struct PickerScreen: View {
    @ObservedObject var model: AppModel
    @ObservedObject var ui: UIState
    let target: PickerTarget
    @State private var query = ""
    @State private var highlight: String?
    @FocusState private var focused: Bool

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    private var filtered: [OCXModel] {
        guard let models = model.ocxModels else { return [] }
        guard !trimmed.isEmpty else { return models }
        return models.filter { $0.id.localizedStandardContains(trimmed) }
    }

    private var showCustom: Bool {
        !trimmed.isEmpty && !(model.ocxModels ?? []).contains { $0.id == trimmed }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Модель: \(target.alias)", backLabel: "Назад", back: { ui.back() }) {
                Color.clear.frame(width: 1, height: 1)
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Поиск или свой id модели", text: $query)
                    .textFieldStyle(.plain).focused($focused)
                    .onSubmit { submit() }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.escape) {
                        if query.isEmpty { return .ignored }
                        query = ""
                        return .handled
                    }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).accessibilityLabel("Очистить поиск")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .glassSurface(Capsule())
            .padding(.horizontal, Theme.edge).padding(.bottom, 10)
            if model.ocxModels == nil {
                Label("Каталог ocx недоступен. Можно ввести id вручную и нажать Return.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .padding(.horizontal, 16).padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if showCustom { row(id: trimmed, title: "Использовать «\(trimmed)»", context: nil, custom: true) }
                        ForEach(filtered) { m in
                            row(id: m.id, title: m.id, context: m.contextLength, custom: false)
                        }
                        if filtered.isEmpty, !showCustom, model.ocxModels != nil {
                            Text("Ничего не найдено").foregroundStyle(.secondary).padding(24)
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .softScrollEdges()
                .frame(maxHeight: .infinity)
                .onChange(of: highlight) { _, h in if let h { proxy.scrollTo(h) } }
            }
        }
        .onAppear {
            highlight = target.current
            Task { try? await Task.sleep(nanoseconds: 60_000_000); focused = true }
        }
        .onChange(of: query) { _, _ in highlight = showCustom ? trimmed : filtered.first?.id }
    }

    private func row(id: String, title: String, context: Int?, custom: Bool) -> some View {
        Button { ui.choose(id, for: target) } label: {
            HStack(spacing: 8) {
                Image(systemName: custom ? "plus" : "checkmark").opacity(custom || id == target.current ? 1 : 0)
                    .frame(width: 14)
                Text(title).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if let c = context { Text("\(c / 1000)k").font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 10).frame(minHeight: 34).contentShape(Rectangle())
            .background(highlight == id ? Color.accentColor.opacity(0.22) : .clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .id(id)
        .accessibilityAddTraits(id == target.current ? .isSelected : [])
    }

    private var ids: [String] { (showCustom ? [trimmed] : []) + filtered.map(\.id) }

    private func move(_ d: Int) {
        let all = ids
        guard !all.isEmpty else { return }
        let cur = highlight.flatMap { all.firstIndex(of: $0) } ?? -1
        highlight = all[min(max(cur + d, 0), all.count - 1)]
    }

    private func submit() {
        if let h = highlight, ids.contains(h) { ui.choose(h, for: target) }
        else if !trimmed.isEmpty { ui.choose(trimmed, for: target) }
    }
}
