import SwiftUI
import WidgetKit

struct TodayListView: View {
    let snapshot: WidgetSnapshot
    let now: Date
    let palette: WidgetPalette
    let maxRows: Int

    /// User-chosen multiplier for course-name font, read from the App
    /// Group at struct init. The main app reloads widget timelines after
    /// changing the value, so the next render picks up the new scale.
    private let userScale: CGFloat = CGFloat(CourseCardFontScaleStore().read())

    /// Dynamic-Type-anchored baseline for the system `.caption` font.
    /// `@ScaledMetric(relativeTo:)` keeps the course-name label moving
    /// with the user's system text-size preference so the surrounding
    /// `.caption.weight(.bold)` / `.caption2` row metadata (still
    /// semantic) doesn't drift away from it under Accessibility text
    /// sizes.
    @ScaledMetric(relativeTo: .caption) private var captionBase: CGFloat = 12

    var body: some View {
        Group {
            if !snapshot.isLoggedIn {
                VStack {
                    Spacer()
                    Text(String(localized: "widget_sign_in"))
                        .font(.callout)
                        .foregroundStyle(palette.onSurfaceVariant)
                    Spacer()
                }
            } else {
                loggedInBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var loggedInBody: some View {
        let weekday = WidgetTimelineDerivation.weekdayFor(now)
        let isWeekend = weekday == 6 || weekday == 7
        let order = snapshot.periodOrder
        let todayCourses = sortedCoursesForToday(weekday: weekday, order: order)
        let ongoingNos = ongoingCourseNos(snapshot: snapshot, now: now)

        VStack(alignment: .leading, spacing: 6) {
            header(weekday: weekday)
            if todayCourses.isEmpty {
                Spacer()
                Text(String(localized: isWeekend
                            ? "widget_no_classes_weekend"
                            : "widget_no_classes_today"))
                    .font(.callout)
                    .foregroundStyle(palette.onSurfaceVariant)
                Spacer()
            } else {
                ForEach(Array(todayCourses.prefix(maxRows)), id: \.courseNo) { course in
                    row(course: course, weekday: weekday, isOngoing: ongoingNos.contains(course.courseNo))
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func sortedCoursesForToday(weekday: Int, order: [String]) -> [SnapshotCourse] {
        let todayKey = WidgetTimelineDerivation.dateKey(for: now)
        return snapshot.courses
            .filter { $0.schedule[weekday] != nil && !$0.skippedDates.contains(todayKey) }
            .sorted { lhs, rhs in
                let lp = lhs.schedule[weekday] ?? []
                let rp = rhs.schedule[weekday] ?? []
                let li = firstChronologicalIndex(in: lp, order: order)
                let ri = firstChronologicalIndex(in: rp, order: order)
                return li < ri
            }
    }

    private func firstChronologicalIndex(in periods: [String], order: [String]) -> Int {
        var minIndex = Int.max
        for periodId in periods {
            if let idx = order.firstIndex(of: periodId), idx < minIndex {
                minIndex = idx
            }
        }
        return minIndex
    }

    private func header(weekday: Int) -> some View {
        let dayName = String(localized: String.LocalizationValue(weekdayKey(weekday)))
        let title = String.localizedStringWithFormat(
            String(localized: "widget_today_weekday_title"), dayName
        )
        return Text(title)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(palette.onSurface)
    }

    private func row(course: SnapshotCourse, weekday: Int, isOngoing: Bool) -> some View {
        let order = snapshot.periodOrder
        let periods = WidgetTimelineDerivation.sortPeriods(course.schedule[weekday] ?? [], by: order)
        let first = periods.first ?? ""
        let last = periods.last ?? ""
        let startTime = snapshot.periodTimes[first]?.start ?? ""
        let endTime = snapshot.periodTimes[last]?.end ?? ""
        let range = first == last ? first : "\(first)–\(last)"

        let rowFill: Color = isOngoing ? Color(widgetHex: course.colorHex) : palette.surface
        let primary: Color = isOngoing ? .white : palette.onSurface
        let secondary: Color = isOngoing ? Color.white.opacity(0.85) : palette.onSurfaceVariant

        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(range)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(primary)
                Text("\(startTime)–\(endTime)")
                    .font(.caption2)
                    .foregroundStyle(secondary)
            }
            .frame(width: 60, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(course.displayName)
                    .font(.system(size: captionBase * userScale, weight: .medium))
                    .foregroundStyle(primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if !course.classroom.isEmpty {
                    Text(course.classroom)
                        .font(.caption2)
                        .foregroundStyle(secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(rowFill, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
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

    private func ongoingCourseNos(snapshot: WidgetSnapshot, now: Date) -> Set<String> {
        let derived = WidgetTimelineDerivation.derive(snapshot: snapshot, at: now)
        if case .ongoing(let infos) = derived {
            return Set(infos.map { $0.course.courseNo })
        }
        return []
    }
}
