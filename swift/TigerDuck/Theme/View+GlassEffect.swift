import SwiftUI

extension View {
    func glassCard(cornerRadius: CGFloat = TigerDuckTheme.CornerRadius.lg) -> some View {
        self
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
            .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
    }

    func glassChip(isSelected: Bool = false) -> some View {
        self
            .padding(.horizontal, TigerDuckTheme.Spacing.md)
            .padding(.vertical, TigerDuckTheme.Spacing.sm)
            .background {
                if isSelected {
                    Capsule().fill(Color.accentColor)
                } else {
                    Capsule().fill(.ultraThinMaterial)
                }
            }
    }
}
