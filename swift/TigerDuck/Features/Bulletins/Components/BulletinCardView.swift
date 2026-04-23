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
            // Org / importance / deleted / date row. Unread indicator lives
            // here (not in a side gutter) so it stays close to the metadata
            // and doesn't burn a column for read rows.
            HStack(spacing: TigerDuckTheme.Spacing.xs) {
                if !isRead {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 7, height: 7)
                        .accessibilityLabel("未讀")
                }
                if let org = bulletin.canonicalOrg {
                    Text(taxonomy.orgLabel(for: org))
                        .font(TigerDuckTheme.Typography.caption)
                        .foregroundStyle(orgLabelColor(policy: policy))
                }
                if let importance = bulletin.importance, importance == .high {
                    importanceBadge
                }
                if bulletin.isDeleted {
                    Text("已撤下")
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
                        .foregroundStyle(policy.secondaryTextColor)
                }
            }

            Text(bulletin.displayTitle)
                .font(TigerDuckTheme.Typography.headline)
                .fontWeight(isRead ? .regular : .semibold)
                .foregroundStyle(policy.primaryTextColor)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            if let summary = bulletin.summary, !summary.isEmpty {
                Text(summary)
                    .font(summaryFont(policy: policy))
                    .foregroundStyle(policy.secondaryTextColor)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            if !bulletin.contentTags.isEmpty {
                tagStrip
            }
        }
        .cardPadding()
        .presetCard(policy: policy)
        .opacity(bulletin.isDeleted ? 0.55 : 1)
    }

    /// Compact trailing tag strip. Capsules previously took a noticeable
    /// chunk of card height; now we use plain accented text joined with
    /// `·` separators and cap at three labels with an overflow counter.
    /// Same information, ~40% less vertical space.
    private var tagStrip: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            let visible = bulletin.contentTags.prefix(3)
            let overflow = bulletin.contentTags.count - visible.count
            Text(visible.map { taxonomy.tagLabel(for: $0) }.joined(separator: " · "))
                .font(TigerDuckTheme.Typography.caption2)
                .foregroundStyle(Color.accentPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            if overflow > 0 {
                Text("+\(overflow)")
                    .font(TigerDuckTheme.Typography.caption2)
                    .foregroundStyle(Color.textSecondary)
            }
        }
    }

    /// Capsule-style "重要" badge replaces the previous warning triangle.
    /// The triangle read as a hard error / network failure cue; a tinted
    /// label communicates "high-priority bulletin" without alarming.
    private var importanceBadge: some View {
        Text("重要")
            .font(TigerDuckTheme.Typography.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.18), in: Capsule())
            .foregroundStyle(Color.orange)
    }

    private func orgLabelColor(policy: VisualStylePolicy) -> Color {
        switch policy.preset {
        case .default: return Color.accentPrimary
        case .iosInspired: return Color.accentColor
        }
    }

    private func summaryFont(policy: VisualStylePolicy) -> Font {
        switch policy.preset {
        case .default: return TigerDuckTheme.Typography.body
        case .iosInspired: return .subheadline
        }
    }
}
