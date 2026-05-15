import SwiftUI

struct WeekGridView: View {
    let snapshot: WidgetSnapshot
    let now: Date
    let palette: WidgetPalette

    var body: some View {
        Group {
            if !snapshot.isLoggedIn {
                Text(String(localized: "widget_sign_in"))
                    .font(.callout)
                    .foregroundStyle(palette.onSurfaceVariant)
            } else {
                grid
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var grid: some View {
        let weekdays = snapshot.activeWeekdays
        let periods = snapshot.activePeriodIds
        let todayWeekday = WidgetTimelineDerivation.weekdayFor(now)

        VStack(spacing: 2) {
            headerRow(weekdays: weekdays, todayWeekday: todayWeekday)
            ForEach(periods, id: \.self) { periodId in
                HStack(spacing: 2) {
                    Text(periodId)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(palette.onSurfaceVariant)
                        .frame(width: 16, alignment: .center)
                    ForEach(weekdays, id: \.self) { weekday in
                        cell(weekday: weekday, periodId: periodId)
                    }
                }
            }
        }
    }

    private func headerRow(weekdays: [Int], todayWeekday: Int) -> some View {
        HStack(spacing: 2) {
            Spacer().frame(width: 16)
            ForEach(weekdays, id: \.self) { weekday in
                VStack(spacing: 2) {
                    Text(String(localized: String.LocalizationValue(weekdayKey(weekday))))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(palette.onSurface)
                    Rectangle()
                        .fill(weekday == todayWeekday ? palette.highlight : Color.clear)
                        .frame(height: 2)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func cell(weekday: Int, periodId: String) -> some View {
        let course = snapshot.courses.first { $0.schedule[weekday]?.contains(periodId) == true }
        return Group {
            if let course {
                VStack(spacing: 1) {
                    Text(course.displayName)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if !course.classroom.isEmpty {
                        Text(course.classroom)
                            .font(.system(size: 7))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(2)
                .background(Color(widgetHex: course.colorHex), in: RoundedRectangle(cornerRadius: 3))
            } else {
                Rectangle()
                    .fill(palette.emptyCell)
                    .cornerRadius(3)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 24)
    }

    private func weekdayKey(_ weekday: Int) -> String {
        switch weekday {
        case 1: return "weekday_mon_short"
        case 2: return "weekday_tue_short"
        case 3: return "weekday_wed_short"
        case 4: return "weekday_thu_short"
        case 5: return "weekday_fri_short"
        case 6: return "weekday_sat_short"
        default: return "weekday_sun_short"
        }
    }
}
