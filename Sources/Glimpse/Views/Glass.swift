import SwiftUI

extension View {
    /// Liquid Glass on macOS 26, and a translucent material on earlier versions.
    /// Reduce Transparency gives a solid surface, and Increase Contrast adds a clear border.
    func glassSurface<S: Shape>(_ shape: S, interactive: Bool = false) -> some View {
        modifier(GlassSurface(shape: shape, interactive: interactive))
    }

    @ViewBuilder
    func prominentGlassButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    func glassButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }
}

private struct GlassSurface<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        surface(content)
            .overlay {
                if contrast == .increased {
                    shape.stroke(Color.white.opacity(0.65), lineWidth: 1.5)
                }
            }
    }

    @ViewBuilder
    private func surface(_ content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Color(white: 0.14), in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.18), lineWidth: 1))
                .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
        } else if #available(macOS 26.0, *) {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
        }
    }
}
