import AppKit
import LanModelCore
import SwiftUI

@main
struct LanModelBarApp: App {
    @StateObject private var model: AppModel
    @StateObject private var ui: UIState

    init() {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("service", isDirectory: true)
        let hasInstaller = bundled.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("install.sh").path) } ?? false
        let m = AppModel(deps: Dependencies(installDirectory: hasInstaller ? bundled : nil))
        m.reloadFiles()
        _model = StateObject(wrappedValue: m)
        _ui = StateObject(wrappedValue: UIState(model: m))
        // Polls for the lifetime of the app, so the menu bar icon stays current while the window is closed.
        Task { @MainActor in
            while true {
                await m.refresh()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            RootView(model: model, ui: ui)
        } label: {
            Image(systemName: model.summary.overall.symbol)
                .symbolRenderingMode(.palette)
                .foregroundStyle(model.summary.overall.color, .primary)
                .accessibilityLabel("\(S.appName): \(S.overallLabel(model.summary.overall))")
        }
        .menuBarExtraStyle(.window)
    }
}
