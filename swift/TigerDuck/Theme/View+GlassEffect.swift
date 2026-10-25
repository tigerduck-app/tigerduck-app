import SwiftUI

extension View {
    func glassCard(cornerRadius: CGFloat = TigerDuckTheme.CornerRadius.lg) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius))
    }

    func glassChip(isSelected: Bool = false) -> some View {
        self
            .padding(.horizontal, TigerDuckTheme.Spacing.md)
            .padding(.vertical, TigerDuckTheme.Spacing.sm)
            .background {
                if isSelected {
                    Capsule().fill(.tint)
                } else {
                    Capsule().fill(.ultraThinMaterial)
                }
            }
    }
}

private struct GlassCardModifier: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(GlassCard.surface(colorScheme))
                .glassCardShadow()
        )
    }
}

/// The glass card's surface and shadow, which `presetCardRow` draws apart.
enum GlassCard {
    // The material over the flat light page reads as grey, so light cards are white.
    static func surface(_ colorScheme: ColorScheme) -> AnyShapeStyle {
        colorScheme == .light ? AnyShapeStyle(Color.white) : AnyShapeStyle(.ultraThinMaterial)
    }
}

extension View {
    func glassCardShadow() -> some View {
        shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
    }
}
