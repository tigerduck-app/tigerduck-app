import SwiftUI

struct BulletinCardView: View {
    let bulletin: BulletinAPI.BulletinSummary
    let taxonomy: BulletinTaxonomyStore

    @Environment(AppState.self) private var appState

    var body: some View {
        let policy = appState.visualStylePolicy
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.sm) {
            HStack(spacing: TigerDuckTheme.Spacing.xs) {
                if let org = bulletin.canonicalOrg {
                    Text(taxonomy.orgLabel(for: org))
                        .font(TigerDuckTheme.Typography.caption)
                        .foregroundStyle(orgLabelColor(policy: policy))
                }
                if let importance = bulletin.importance, importance == .high {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.orange)
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

            Text(bulletin.title)
                .font(TigerDuckTheme.Typography.headline)
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
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: TigerDuckTheme.Spacing.xs) {
                        ForEach(bulletin.contentTags, id: \.self) { tag in
                            Text(taxonomy.tagLabel(for: tag))
                                .font(TigerDuckTheme.Typography.caption2)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.accentPrimary.opacity(0.12), in: Capsule())
                                .foregroundStyle(Color.accentPrimary)
                        }
                    }
                }
            }
        }
        .cardPadding()
        .presetCard(policy: policy)
        .opacity(bulletin.isDeleted ? 0.55 : 1)
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
