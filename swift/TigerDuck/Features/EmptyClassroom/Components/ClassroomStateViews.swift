import SwiftUI

/// A glyph and a short title in a card, for a failure, a day without data or a holiday, with
/// the one action that leads on from it.
struct ClassroomStateCard<Action: View>: View {
    let systemImage: String
    let title: String
    let policy: VisualStylePolicy
    @ViewBuilder let action: Action

    @ScaledMetric(relativeTo: .largeTitle) private var glyphSize: CGFloat = 34

    var body: some View {
        VStack(spacing: TigerDuckTheme.Spacing.md) {
            Image(systemName: systemImage)
                .font(.system(size: glyphSize))
                .foregroundStyle(policy.secondaryTextColor)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
                .foregroundStyle(policy.primaryTextColor)
                .multilineTextAlignment(.center)
            action
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        .padding(.vertical, TigerDuckTheme.Spacing.xl)
        .frame(maxWidth: .infinity)
        .presetCard(policy: policy)
    }
}

/// The chip under no data and a holiday, which moves to the next teaching day.
struct NextTeachingDayButton: View {
    let day: Date
    let onSelect: (Date) -> Void

    var body: some View {
        Button {
            onSelect(day)
        } label: {
            HStack(spacing: TigerDuckTheme.Spacing.sm) {
                Text(EmptyClassroomViewModel.dateText(day))
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.bold))
                    .accessibilityHidden(true)
            }
            .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
    }
}

/// Rows of grey shapes where the rooms will be.
struct ClassroomSkeleton: View {
    let policy: VisualStylePolicy

    @ScaledMetric(relativeTo: .headline) private var roomWidth: CGFloat = 66

    var body: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.sm) {
            Capsule()
                .fill(Color.textPrimary.opacity(0.12))
                .frame(width: 24, height: 12)
                .padding(.horizontal, TigerDuckTheme.Spacing.xs)
            VStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { index in
                    if index > 0 {
                        Divider().padding(.leading, TigerDuckTheme.Spacing.lg)
                    }
                    HStack(spacing: TigerDuckTheme.Spacing.md) {
                        Capsule()
                            .fill(Color.textPrimary.opacity(0.14))
                            .frame(width: roomWidth, height: 14)
                        Capsule()
                            .fill(Color.textPrimary.opacity(0.08))
                            .frame(height: 6)
                        Capsule()
                            .fill(Color.textPrimary.opacity(0.1))
                            .frame(width: 40, height: 12)
                    }
                    .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                    .frame(height: 50)
                }
            }
            .presetCard(policy: policy)
        }
        .accessibilityRepresentation { ProgressView() }
    }
}
