import Defaults
import SwiftUI

struct EventRowView: View {
    let event: SDCalendarEvent

    #if os(iOS)
    @Environment(AppState.self) private var appState
    #endif

    #if os(iOS)
    /// Only a holiday can be opted back into: a term boundary is an announcement,
    /// not a day off, so its `holidayID` is nil and no toggle appears. iOS only,
    /// as macOS delivers no class reminders; the Mac still lists the holiday.
    ///
    /// Read from `Defaults`, not mirrored into `@State`: a cloud-sync merge writes
    /// this key through `AcademicCalendarStore.applySyncedOverrides`, so a change on
    /// another device moves the switch while the row is on screen. A copy seeded in
    /// `onAppear` would keep showing the value from when the row first appeared.
    @Default(.holidayNotifyOverrides) private var holidayOverrides
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
                // Labelled, since a bare switch leaves the user guessing what it governs.
                // A separate `Text` sits where this row wants it, not where a `Toggle`
                // label goes; with `labelsHidden`, the accessibility label is set below.
                Text(String(localized: "calendar_holiday_notify_title"))
                    .font(TigerDuckTheme.Typography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                Toggle(
                    "",
                    isOn: Binding(
                        get: { holidayOverrides.contains(holidayID) },
                        // Through AppState, not Defaults directly, so the local
                        // write, Live Activity refresh and upload stay in one place.
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
}
