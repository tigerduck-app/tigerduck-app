import SwiftUI

extension View {
    func presetCard(
        policy: VisualStylePolicy,
        cornerRadius: CGFloat = TigerDuckTheme.CornerRadius.lg
    ) -> some View {
        modifier(PresetCardModifier(policy: policy, cornerRadius: cornerRadius))
    }

    func presetChip(
        policy: VisualStylePolicy,
        isSelected: Bool
    ) -> some View {
        modifier(PresetChipModifier(policy: policy, isSelected: isSelected))
    }

    func presetGroupedListContainer(policy: VisualStylePolicy) -> some View {
        modifier(PresetGroupedListContainerModifier(policy: policy))
    }
}

// Shadows go on the background shape, not on `content`: SwiftUI applies `.shadow`
// to every leaf it reaches, adding a blurred halo (an offscreen pass) per label on
// top of the material. One shadow per card looks the same and costs far less.

private struct PresetCardModifier: ViewModifier {
    let policy: VisualStylePolicy
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        switch policy.cardSurface {
        case .glass:
            content
                .background(
                    // The material over the flat light page reads as grey, so light cards are white.
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(colorScheme == .light ? AnyShapeStyle(Color.white) : AnyShapeStyle(.ultraThinMaterial))
                        .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
                )
        case .grouped:
            content
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(Color.secondarySystemGroupedBackgroundCompat)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(Color.textPrimary.opacity(0.08), lineWidth: 0.5)
                )
        }
    }
}

private struct PresetChipModifier: ViewModifier {
    let policy: VisualStylePolicy
    let isSelected: Bool

    func body(content: Content) -> some View {
        let padded = content
            .padding(.horizontal, TigerDuckTheme.Spacing.md)
            .padding(.vertical, TigerDuckTheme.Spacing.sm)

        switch policy.chipStyle {
        case .glass:
            padded
                .background {
                    if isSelected {
                        Capsule().fill(.tint)
                    } else {
                        Capsule().fill(.ultraThinMaterial)
                    }
                }
        case .filledCapsule:
            padded
                .background {
                    if isSelected {
                        Capsule().fill(.tint)
                    } else {
                        Capsule().fill(Color.textPrimary.opacity(0.08))
                    }
                }
        }
    }
}

private struct PresetGroupedListContainerModifier: ViewModifier {
    let policy: VisualStylePolicy

    func body(content: Content) -> some View {
        switch policy.assignmentRowStyle {
        case .card:
            content
        case .groupedList:
            content
                .background(
                    RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.lg)
                        .fill(Color.secondarySystemGroupedBackgroundCompat)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.lg)
                        .strokeBorder(Color.textPrimary.opacity(0.08), lineWidth: 0.5)
                )
        }
    }
}
