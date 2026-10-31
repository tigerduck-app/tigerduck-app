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

    /// Draws a `presetCard` behind each row of a lazy list, which builds only the rows on screen,
    /// so a long list still reads as one card without building every row up front.
    func presetCardRow(policy: VisualStylePolicy, isFirst: Bool, isLast: Bool) -> some View {
        background { PresetCardRow(policy: policy, isFirst: isFirst, isLast: isLast) }
    }
}

// Shadows go on the background shape, not on `content`: SwiftUI applies `.shadow`
// to every leaf it reaches, adding a blurred halo (an offscreen pass) per label on
// top of the material. One shadow per card looks the same and costs far less.

private struct PresetCardModifier: ViewModifier {
    let policy: VisualStylePolicy
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        switch policy.cardSurface {
        case .glass:
            content.glassCard(cornerRadius: cornerRadius)
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

/// The card runs on past the row where a neighbour continues it, and a clip at the row cuts it
/// there; the clip is wider than the row and reaches past the card's two ends, for the shadow. A
/// material blurs everything under its frame, so the glass surface covers only the row, and the
/// shadow comes from a card in the page's color under it.
private struct PresetCardRow: View {
    let policy: VisualStylePolicy
    let isFirst: Bool
    let isLast: Bool
    @Environment(\.colorScheme) private var colorScheme

    private static let reach: CGFloat = 48
    private static let cornerRadius = TigerDuckTheme.CornerRadius.lg

    var body: some View {
        switch policy.cardSurface {
        case .glass:
            ZStack {
                runningOn(
                    RoundedRectangle(cornerRadius: Self.cornerRadius)
                        .fill(Color.backgroundPrimary)
                        .glassCardShadow()
                )
                UnevenRoundedRectangle(
                    topLeadingRadius: isFirst ? Self.cornerRadius : 0,
                    bottomLeadingRadius: isLast ? Self.cornerRadius : 0,
                    bottomTrailingRadius: isLast ? Self.cornerRadius : 0,
                    topTrailingRadius: isFirst ? Self.cornerRadius : 0
                )
                .fill(GlassCard.surface(colorScheme))
            }
        case .grouped:
            runningOn(Color.clear.presetCard(policy: policy, cornerRadius: Self.cornerRadius))
        }
    }

    private func runningOn(_ card: some View) -> some View {
        let top = isFirst ? Self.reach : 0
        let bottom = isLast ? Self.reach : 0
        return card
            .padding(.top, top - Self.reach)
            .padding(.bottom, bottom - Self.reach)
            .padding(EdgeInsets(top: top, leading: Self.reach, bottom: bottom, trailing: Self.reach))
            .clipped()
            .padding(EdgeInsets(top: -top, leading: -Self.reach, bottom: -bottom, trailing: -Self.reach))
    }
}
