import Defaults
import SwiftUI

struct EventRowView: View {
    let event: SDCalendarEvent

    #if os(iOS)
    @Environment(AppState.self) private var appState
    #endif

    #if os(iOS)
    @Default(.holidayNotifyOverrides) private var holidayOverrides
    #endif

    var body: some View {
        HStack(spacing: TigerDuckTheme.Spacing.md) {
            Circle()
                .fill(event.source.color)
                .frame(width: 10, height: 10)

            if Self.showsTime(of: event) {
                Text(event.date.timeString)
                    .font(TigerDuckTheme.Typography.body)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

            Text(event.title)
                .font(TigerDuckTheme.Typography.body)
                .foregroundStyle(Color.textPrimary)

            Spacer()

            #if os(iOS)
            if let holidayID {
                Text(String(localized: "calendar_holiday_notify_title"))
                    .font(TigerDuckTheme.Typography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                Toggle(
                    "",
                    isOn: Binding(
                        get: { holidayOverrides.contains(holidayID) },
                        set: { appState.setHolidayNotify($0, holidayID: holidayID) }
                    )
                )
                .labelsHidden()
                .accessibilityLabel(
                    Text(String(localized: "calendar_holiday_notify_title"))
                )
            } else {
                sourceLabel
            }
            #else
            sourceLabel
            #endif
        }
        .cardPadding()
        .glassCard()
    }

    private var sourceLabel: some View {
        Text(event.source.label)
            .font(TigerDuckTheme.Typography.caption)
            .foregroundStyle(event.source.color)
    }

    private var holidayID: Int? {
        AcademicCalendar.holidayID(for: event)
    }

    static func showsTime(of event: SDCalendarEvent) -> Bool {
        !event.isAllDay
    }
}
