import SwiftUI

struct AnnouncementCardView: View {
    let announcement: SDAnnouncement

    var body: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.sm) {
            HStack {
                Text(announcement.department)
                    .font(TigerDuckTheme.Typography.caption)
                    .foregroundStyle(Color.accentPrimary)
                Spacer()
                Text(announcement.publishDate.shortDateString)
                    .font(TigerDuckTheme.Typography.caption)
                    .foregroundStyle(Color.textSecondary)
            }

            Text(announcement.title)
                .font(TigerDuckTheme.Typography.headline)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            HStack {
                Text(announcement.summary)
                    .font(TigerDuckTheme.Typography.body)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
            }
        }
        .cardPadding()
        .glassCard()
    }
}
