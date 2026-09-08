import SwiftUI

struct EventRowView: View {
    let event: SDCalendarEvent

    #if os(iOS)
    @Environment(AppState.self) private var appState
    #endif

    #if os(iOS)
    /// Only a holiday can be opted back into. A term boundary is an
    /// announcement, not a day off, so `holidayID` is nil for one and the
    /// toggle never appears.
    ///
    /// iOS only: macOS delivers no class reminders, so a switch there would
    /// promise something the platform cannot do. The Mac still lists the
    /// holiday — it just has nothing to turn on.
    @State private var notifyOnHoliday = false
    #endif

    var body: some View {
        HStack(spacing: TigerDuckTheme.Spacing.md) {
            Circle()
                .fill(event.source.color)
                .frame(width: 10, height: 10)

            // A holiday is an all-day thing, so "00:00" was never telling
            // the user anything.
            if holidayID == nil {
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
                // Labelled rather than bare: on its own the switch asked the
                // user to guess what it governed. `labelsHidden` stays so the
                // text sits where this row wants it instead of where a
                // `Toggle` label would land, which is why the accessibility
                // label is still spelled out below.
                Text(String(localized: "calendar_holiday_notify_title"))
                    .font(TigerDuckTheme.Typography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                Toggle("", isOn: $notifyOnHoliday)
                    .labelsHidden()
                    .accessibilityLabel(
                        Text(String(localized: "calendar_holiday_notify_title"))
                    )
                    .onChange(of: notifyOnHoliday) { _, on in
                        appState.setHolidayNotify(on, holidayID: holidayID)
                    }
                    .onAppear {
                        notifyOnHoliday = AcademicCalendarStore.shared
                            .optedInHolidayIDs.contains(holidayID)
                    }
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
        CalendarViewModel.holidayID(for: event)
    }
}
