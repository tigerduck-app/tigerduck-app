import SwiftUI

struct AnnouncementCardView: View {
    let announcement: SDAnnouncement

    @Environment(AppState.self) private var appState

    var body: some View {
        let policy = appState.visualStylePolicy
        return VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.sm) {
            HStack {
                Text(announcement.department)
                    .font(TigerDuckTheme.Typography.caption)
                    .foregroundStyle(departmentColor(policy: policy))
                Spacer()
                Text(announcement.publishDate.shortDateString)
                    .font(TigerDuckTheme.Typography.caption)
                    .foregroundStyle(secondaryTextColor(policy: policy))
            }

            Text(announcement.title)
                .font(TigerDuckTheme.Typography.headline)
                .foregroundStyle(primaryTextColor(policy: policy))
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            HStack(alignment: .top) {
                Text(announcement.summary)
                    .font(summaryFont(policy: policy))
                    .foregroundStyle(secondaryTextColor(policy: policy))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(secondaryTextColor(policy: policy))
            }
        }
        .cardPadding()
        .presetCard(policy: policy)
    }

    // In iOS preset the summary should feel like metadata rather than
    // body text — that pulls visual weight back to the title.
    private func summaryFont(policy: VisualStylePolicy) -> Font {
        switch policy.preset {
        case .default: return TigerDuckTheme.Typography.body
        case .iosInspired: return .subheadline
        }
    }

    private func primaryTextColor(policy: VisualStylePolicy) -> Color {
        switch policy.preset {
        case .default: return Color.textPrimary
        case .iosInspired: return .primary
        }
    }

    private func secondaryTextColor(policy: VisualStylePolicy) -> Color {
        switch policy.preset {
        case .default: return Color.textSecondary
        case .iosInspired: return .secondary
        }
    }

    private func departmentColor(policy: VisualStylePolicy) -> Color {
        switch policy.preset {
        case .default: return Color.accentPrimary
        case .iosInspired: return Color.accentColor
        }
    }
}
