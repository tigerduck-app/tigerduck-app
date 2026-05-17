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
                EmptyStateView(icon: "calendar.badge.checkmark", title: String(localized: "calendar_no_events_today"))
                    .frame(height: 120)
            } else {
                ForEach(events, id: \.eventId) { event in
                    EventRowView(event: event)
                }
                .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        f.timeZone = AppConstants.taipeiTimeZone
        return f
    }()

    private var dateTitle: String {
        let dateStr = Self.dateFormatter.string(from: date)
        return date.isToday
            ? dateStr + String(localized: "calendar_date_today_suffix")
            : dateStr
    }
}
