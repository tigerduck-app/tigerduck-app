import SwiftUI

struct EventRowView: View {
    let event: SDCalendarEvent

    var body: some View {
        HStack(spacing: TigerDuckTheme.Spacing.md) {
            Circle()
                .fill(event.source.color)
                .frame(width: 10, height: 10)

            Text(event.date.timeString)
                .font(TigerDuckTheme.Typography.body)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            Text(event.title)
                .font(TigerDuckTheme.Typography.body)
                .foregroundStyle(Color.textPrimary)

            Spacer()

            Text(event.source.label)
                .font(TigerDuckTheme.Typography.caption)
                .foregroundStyle(event.source.color)
        }
        .cardPadding()
        .glassCard()
    }
}
