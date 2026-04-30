import SwiftUI

struct BulletinCardView: View {
    let bulletin: BulletinAPI.BulletinSummary
    let taxonomy: BulletinTaxonomyStore
    /// Local read state — shows an unread dot in the org row + bolder title
    /// when false. Defaults to true so callers without a read store don't
    /// render "everything unread" by accident.
    var isRead: Bool = true

    @Environment(AppState.self) private var appState

    var body: some View {
        let policy = appState.visualStylePolicy
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.sm) {
            topRow
            titleRow
            summaryRow(policy: policy)
            if !bulletin.contentTags.isEmpty {
                tagStrip
            }
        }
        .cardPadding()
        .presetCard(policy: policy)
        .opacity(bulletin.isDeleted ? 0.55 : 1)
    }

    // MARK: - Rows

    /// Top row: filled org badge on the left, importance/撤下/date on the right.
    /// The badge now lands as a solid accent pill so it reads as the card's
    /// primary metadata anchor — the category strip at the bottom
    /// intentionally uses a lighter hashtag style so the two dimensions
    /// don't compete for attention.
    private var topRow: some View {
        HStack(alignment: .center, spacing: TigerDuckTheme.Spacing.sm) {
            if !isRead {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel(String(localized: "bulletin_unread_dot_label"))
            }
            if let org = bulletin.canonicalOrg {
                orgBadge(label: taxonomy.orgLabel(for: org))
            }
            if let importance = bulletin.importance, importance == .high {
                importanceBadge
            }
            if bulletin.isDeleted {
                Text(String(localized: "bulletin_withdrawn_badge"))
                    .font(TigerDuckTheme.Typography.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.textSecondary.opacity(0.2), in: Capsule())
                    .foregroundStyle(Color.textSecondary)
            }
            Spacer()
            if let posted = bulletin.postedAt {
                Text(posted.shortDateString)
                    .font(TigerDuckTheme.Typography.caption)
                    .foregroundStyle(Color.textSecondary)
            }
        }
    }

    private var titleRow: some View {
        Text(bulletin.displayTitle)
            .font(TigerDuckTheme.Typography.headline)
            .fontWeight(isRead ? .regular : .semibold)
            .foregroundStyle(Color.textPrimary)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
    }

    @ViewBuilder
    private func summaryRow(policy: VisualStylePolicy) -> some View {
        if let summary = bulletin.summary, !summary.isEmpty {
            Text(summary)
                .font(summaryFont(policy: policy))
                .foregroundStyle(Color.textSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
    }

    /// Filled capsule with theme accent fill and white text. Larger than the
    /// previous plain caption so it asserts itself as the card's primary
    /// source signal.
    private func orgBadge(label: String) -> some View {
        Text(label)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.accentColor, in: Capsule())
    }

    /// Hashtag-style inline strip. Pairs intentionally with the filled org
    /// badge above — plain `#tag` text in the secondary color reads as
    /// metadata rather than a second competing chip set.
    private var tagStrip: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            let visible = bulletin.contentTags.prefix(3)
            let overflow = bulletin.contentTags.count - visible.count
            ForEach(Array(visible.enumerated()), id: \.offset) { _, tag in
                Text("#\(taxonomy.tagLabel(for: tag))")
                    .font(TigerDuckTheme.Typography.caption2)
                    .foregroundStyle(Color.textSecondary)
            }
            if overflow > 0 {
                Text("+\(overflow)")
                    .font(TigerDuckTheme.Typography.caption2)
                    .foregroundStyle(Color.textSecondary)
            }
        }
        .lineLimit(1)
    }

    /// Capsule-style "重要" badge — same capsule idiom as org badge but
    /// tinted orange so it reads as a priority signal rather than a source.
    private var importanceBadge: some View {
        Text(String(localized: "bulletin_importance_high_badge"))
            .font(TigerDuckTheme.Typography.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.18), in: Capsule())
            .foregroundStyle(Color.orange)
    }

    private func summaryFont(policy: VisualStylePolicy) -> Font {
        switch policy.preset {
        case .default: return TigerDuckTheme.Typography.body
        case .iosInspired: return .subheadline
        }
    }
}
