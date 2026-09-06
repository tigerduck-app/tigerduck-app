import SwiftUI

// Preset-aware surface modifiers.
//
// These are the preferred entry points for new styling work. They dispatch
// on ``VisualStylePolicy`` so a single call site renders differently
// under different visual presets without scattering `if preset == ...`
// branches through view code. The legacy `glassCard()` / `glassChip()`
// helpers in View+GlassEffect.swift continue to work for pages not yet
// migrated, but new surfaces should go through this file.

extension View {
    /// Preset-aware card surface. Replaces ad-hoc `glassCard()` for
    /// screens that participate in the visual preset system.
    func presetCard(
        policy: VisualStylePolicy,
        cornerRadius: CGFloat = TigerDuckTheme.CornerRadius.lg
    ) -> some View {
        modifier(PresetCardModifier(policy: policy, cornerRadius: cornerRadius))
    }

    /// Preset-aware filter chip. Selected/unselected states are resolved
    /// by the policy, so the caller just passes `isSelected`.
    func presetChip(
        policy: VisualStylePolicy,
        isSelected: Bool
    ) -> some View {
        modifier(PresetChipModifier(policy: policy, isSelected: isSelected))
    }

    /// Preset-aware row surface inside a grouped list. In the default
    /// preset this wraps in a glass card; in iOS preset it just adds
    /// horizontal padding and leaves the parent grouped surface to draw
    /// the background + dividers.
    func presetRow(policy: VisualStylePolicy) -> some View {
        modifier(PresetRowModifier(policy: policy))
    }

    /// Preset-aware container that groups several rows into one iOS-style
    /// grouped list surface. Under the default preset this is a no-op so
    /// existing card-per-row layouts are preserved.
    func presetGroupedListContainer(policy: VisualStylePolicy) -> some View {
        modifier(PresetGroupedListContainerModifier(policy: policy))
    }

    /// Preset-aware search-bar surface.
    func presetSearchBarSurface(policy: VisualStylePolicy) -> some View {
        modifier(PresetSearchBarModifier(policy: policy))
    }
}

// MARK: - Implementation

// Shadows go on the background shape, not on `content`: SwiftUI applies
// `.shadow` to every leaf it can reach, so a card of thirty labels was
// paying for thirty blurred halos (each an offscreen pass) on top of the
// material. One shadow per card is visually the same and far cheaper.

private struct PresetCardModifier: ViewModifier {
    let policy: VisualStylePolicy
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        switch policy.cardSurface {
        case .glass:
            content
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(.ultraThinMaterial)
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
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
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
                        Capsule().fill(Color.accentColor)
                    } else {
                        Capsule().fill(.ultraThinMaterial)
                    }
                }
        case .filledCapsule:
            padded
                .background {
                    if isSelected {
                        Capsule().fill(Color.accentColor)
                    } else {
                        Capsule().fill(Color.white.opacity(0.08))
                    }
                }
        }
    }
}

private struct PresetRowModifier: ViewModifier {
    let policy: VisualStylePolicy

    func body(content: Content) -> some View {
        switch policy.assignmentRowStyle {
        case .card:
            content
                .cardPadding()
                .background(
                    RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.lg)
                        .fill(.ultraThinMaterial)
                        .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
                )
        case .groupedList:
            content
                .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                .padding(.vertical, TigerDuckTheme.Spacing.md)
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
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                )
        }
    }
}

private struct PresetSearchBarModifier: ViewModifier {
    let policy: VisualStylePolicy

    func body(content: Content) -> some View {
        switch policy.searchBarSurface {
        case .glass:
            content
                .padding(TigerDuckTheme.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.sm)
                        .fill(.ultraThinMaterial)
                        .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
                )
        case .grouped:
            content
                .padding(.horizontal, TigerDuckTheme.Spacing.md)
                .padding(.vertical, TigerDuckTheme.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.sm)
                        .fill(Color.white.opacity(0.08))
                )
        }
    }
}
