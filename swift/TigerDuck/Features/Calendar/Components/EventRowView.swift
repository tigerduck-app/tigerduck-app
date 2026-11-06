import Defaults
import SwiftUI

struct EventRowView: View {
    let event: AssignmentStore.CalendarEvent
    var showsDisclosure = false

    #if os(iOS)
    @Environment(AppEnvironment.self) private var app: AppEnvironment?
    #endif

    #if os(iOS)
    @AccountDefault(.holidayNotifyOverrides) private var holidayOverrides
    #endif

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: TigerDuckTheme.Spacing.md) {
            Circle()
                .fill(event.source.color)
                .frame(width: 10, height: 10)

            dynamicTypeSize.rowLayout {
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
                    .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil, alignment: .leading)

                if !dynamicTypeSize.isAccessibilitySize {
                    Spacer()
                }

                trailing
            }

            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
                    .accessibilityHidden(true)
            }
        }
        .cardPadding()
        .glassCard()
    }

    @ViewBuilder
    private var trailing: some View {
        #if os(iOS)
        if let holidayID {
            HStack(spacing: TigerDuckTheme.Spacing.md) {
                Text(String(localized: "calendar_holiday_notify_title"))
                    .font(TigerDuckTheme.Typography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                Toggle(
                    "",
                    isOn: Binding(
                        get: { holidayOverrides.contains(holidayID) },
                        set: { isOn in
                            guard let app else { return }
                            app.holidays.setHolidayNotify(isOn, holidayID: holidayID, for: app.authService.session.currentSignIn)
                        }
                    )
                )
                .labelsHidden()
                .accessibilityLabel(
                    Text(String(localized: "calendar_holiday_notify_title"))
                )
            }
        } else {
            sourceLabel
        }
        #else
        sourceLabel
        #endif
    }

    private var sourceLabel: some View {
        Text(event.source.label)
            .font(TigerDuckTheme.Typography.caption)
            .foregroundStyle(event.source.color)
    }

    private var holidayID: Int? {
        SchoolCalendar.holidayID(for: event)
    }

    static func showsTime(of event: AssignmentStore.CalendarEvent) -> Bool {
        !event.isAllDay
    }
}
