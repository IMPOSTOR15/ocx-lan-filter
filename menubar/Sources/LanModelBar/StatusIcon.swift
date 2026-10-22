import LanModelCore
import SwiftUI

extension OverallStatus {
    var symbol: String {
        switch self {
        case .ok: return "arrow.left.arrow.right.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .down: return "xmark.circle.fill"
        case .paused: return "pause.circle"
        }
    }

    var color: Color {
        switch self {
        case .ok: return .green
        case .warning: return .yellow
        case .down: return .red
        case .paused: return .secondary
        }
    }
}

struct StatusDot: View {
    let state: EndpointState?
    let enabled: Bool
    var body: some View {
        let (symbol, color): (String, Color) = {
            if !enabled { return ("circle", .secondary) }
            switch state {
            case .listening: return ("circle.fill", .green)
            case .error: return ("exclamationmark.circle.fill", .red)
            default: return ("circle.dotted", .orange)
            }
        }()
        Image(systemName: symbol).foregroundStyle(color)
            .accessibilityLabel(enabled ? S.stateLabel(state) : tr("выключен", "off"))
    }
}
