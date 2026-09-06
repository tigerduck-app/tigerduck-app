import SwiftUI

extension View {
    /// Shadow lives on the background shape so it is one offscreen pass
    /// per card instead of one per text leaf (see View+SurfaceStyle).
    func glassCard(cornerRadius: CGFloat = TigerDuckTheme.CornerRadius.lg) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
            )
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
