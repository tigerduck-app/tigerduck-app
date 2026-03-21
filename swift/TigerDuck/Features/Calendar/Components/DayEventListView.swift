import SwiftUI

struct DayEventListView: View {
    let date: Date
    let events: [SDCalendarEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.md) {
            Text(dateTitle)
                .font(TigerDuckTheme.Typography.headline)
                .foregroundStyle(Color.textPrimary)
                .padding(.horizontal, TigerDuckTheme.Spacing.lg)

            if events.isEmpty {
                EmptyStateView(icon: "calendar.badge.checkmark", title: "今日無事件")
                    .frame(height: 120)
            } else {
                ForEach(events, id: \.eventId) { event in
                    EventRowView(event: event)
                }
                .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            }
        }
    }

    private var dateTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh-Hant")
        formatter.dateFormat = "M月d日"
        let dateStr = formatter.string(from: date)
        return date.isToday ? "\(dateStr) (今日)" : dateStr
    }
}
