import SwiftUI

/// Liquid Glass on macOS 26+, blurred material elsewhere. Glass is used for controls and floating bars;
/// content (cards, fields) sits on a quiet fill, so glass never stacks on glass.
enum Theme {
    static let cardRadius: CGFloat = 18
    static let fieldRadius: CGFloat = 10
    static let edge: CGFloat = 14
}

private struct GlassSurface: ViewModifier {
    let shape: AnyShape
    let tint: Color?
    let interactive: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(style, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.10), lineWidth: 0.5))
        }
    }

    @available(macOS 26, *)
    private var style: Glass {
        var g = Glass.regular
        if let tint { g = g.tint(tint) }
        if interactive { g = g.interactive() }
        return g
    }
}

extension View {
    func glassSurface<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(GlassSurface(shape: AnyShape(shape), tint: tint, interactive: interactive))
    }

    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent {
                self.buttonStyle(.glassProminent).buttonBorderShape(.capsule)
            } else {
                self.buttonStyle(.glass).buttonBorderShape(.capsule)
            }
        } else {
            if prominent {
                self.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
            } else {
                self.buttonStyle(.bordered).buttonBorderShape(.capsule)
            }
        }
    }

    @ViewBuilder
    func softScrollEdges() -> some View {
        if #available(macOS 26, *) {
            self.scrollEdgeEffectStyle(.soft, for: .vertical)
        } else {
            self
        }
    }

    /// Content card: a quiet translucent fill with a hairline edge.
    func card(radius: CGFloat = Theme.cardRadius) -> some View {
        background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }

    /// Inset field look for text fields and URL chips.
    func inset(radius: CGFloat = Theme.fieldRadius) -> some View {
        padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    @ViewBuilder
    func glassContainer(spacing: CGFloat = 8) -> some View {
        if #available(macOS 26, *) { GlassEffectContainer(spacing: spacing) { self } } else { self }
    }
}

struct GlassIconButton: View {
    let symbol: String
    let label: String
    var size: CGFloat = 30
    var tint: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .medium))
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassSurface(Circle(), tint: tint, interactive: true)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Section of a form: small caption above a card with rows separated by hairlines.
struct FormCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.leading, 6)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 10) { content }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
        }
    }
}

struct FormRow<Trailing: View>: View {
    let label: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            Text(label)
            Spacer(minLength: 8)
            trailing
        }
        .frame(minHeight: 26)
    }
}
