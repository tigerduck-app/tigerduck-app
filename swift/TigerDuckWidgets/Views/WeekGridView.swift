import SwiftUI

/// Week-at-a-glance grid for the Schedule widget. Mirrors the in-app
/// `TimetableGridView` design: consecutive periods of the same course collapse
/// into a single tall block with a soft tinted fill + matching stroke, empty
/// slots show a neutral surface, and the period/weekday rails use the same
/// secondary-text treatment. Dimensions are scaled down for the widget canvas
/// and derived from `GeometryReader` so a course spanning N periods knows the
/// exact height to overlay.
struct WeekGridView: View {
    let snapshot: WidgetSnapshot
    let now: Date
    let palette: WidgetPalette

    private let rowSpacing: CGFloat = 2
    private let colSpacing: CGFloat = 2
    private let headerHeight: CGFloat = 18
    private let periodWidth: CGFloat = 12
    private let cornerRadius: CGFloat = 4

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
        let lookup = buildLookup()

        GeometryReader { geom in
            let totalRowSpacing = CGFloat(max(0, periods.count - 1)) * rowSpacing
            let available = max(0, geom.size.height - headerHeight - rowSpacing - totalRowSpacing)
            // Floor at a small but nonzero minimum so the edit-mode drag
            // preview can't shrink every cell to height 0 and render the
            // widget as a blank rectangle. The grid is willing to overflow
            // its container rather than disappear — at the family sizes
            // this branch never triggers because `available` is plenty.
            let minCellHeight: CGFloat = 6
            let computed = periods.isEmpty ? 0 : available / CGFloat(periods.count)
            let cellHeight = periods.isEmpty ? 0 : max(minCellHeight, computed)
            // Scale text with cell height so systemExtraLarge (iPad, ~38pt
            // cells) doesn't render the same 9pt text as systemLarge (iPhone,
            // ~17pt cells). Clamped so the small-widget case stays compact.
            let fontScale = min(1.6, max(1.0, cellHeight / 17.0))

            VStack(spacing: rowSpacing) {
                headerRow(weekdays: weekdays, todayWeekday: todayWeekday, fontScale: fontScale)
                ForEach(Array(periods.enumerated()), id: \.offset) { periodIndex, periodId in
                    HStack(spacing: colSpacing) {
                        Text(periodId)
                            .font(.system(size: 8 * fontScale))
                            .foregroundStyle(palette.onSurfaceVariant)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(width: periodWidth, height: cellHeight)

                        ForEach(weekdays, id: \.self) { weekday in
                            cellView(
                                weekday: weekday,
                                periodIndex: periodIndex,
                                periods: periods,
                                lookup: lookup,
                                cellHeight: cellHeight,
                                fontScale: fontScale
                            )
                            .frame(maxWidth: .infinity)
                            .frame(height: cellHeight)
                        }
                    }
                }
            }
        }
    }

    private func headerRow(weekdays: [Int], todayWeekday: Int, fontScale: CGFloat) -> some View {
        HStack(spacing: colSpacing) {
            Color.clear.frame(width: periodWidth, height: headerHeight)
            ForEach(weekdays, id: \.self) { weekday in
                VStack(spacing: 1) {
                    Text(String(localized: String.LocalizationValue(weekdayKey(weekday))))
                        .font(.system(size: 7 * fontScale, weight: .bold))
                        .foregroundStyle(palette.onSurfaceVariant)
                    Rectangle()
                        .fill(weekday == todayWeekday ? palette.highlight : Color.clear)
                        .frame(height: 1.5)
                }
                .frame(maxWidth: .infinity)
                .frame(height: headerHeight)
            }
        }
    }

    @ViewBuilder
    private func cellView(
        weekday: Int,
        periodIndex: Int,
        periods: [String],
        lookup: [Int: [String: SnapshotCourse]],
        cellHeight: CGFloat,
        fontScale: CGFloat
    ) -> some View {
        switch cellRole(weekday: weekday, periodIndex: periodIndex, periods: periods, lookup: lookup) {
        case .empty:
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(palette.emptyCell)

        case .blockStart(let course, let spanCount):
            let totalHeight = CGFloat(spanCount) * cellHeight + CGFloat(spanCount - 1) * rowSpacing
            let courseColor = Color(widgetHex: course.colorHex)
            Color.clear
                .overlay(alignment: .top) {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(courseColor.opacity(0.25))
                        .overlay {
                            RoundedRectangle(cornerRadius: cornerRadius)
                                .strokeBorder(courseColor.opacity(0.4), lineWidth: 0.5)
                        }
                        .overlay {
                            VStack(spacing: 1) {
                                Text(course.displayName)
                                    .font(.system(size: 9 * fontScale, weight: .medium))
                                    .foregroundStyle(palette.onSurface)
                                    .lineLimit(spanCount > 1 ? 3 : 2)
                                    .multilineTextAlignment(.center)
                                    .minimumScaleFactor(0.7)
                                if !course.classroom.isEmpty && spanCount > 1 {
                                    Text(course.classroom)
                                        .font(.system(size: 7 * fontScale))
                                        .foregroundStyle(palette.onSurfaceVariant)
                                        .lineLimit(1)
                                }
                            }
                            .padding(2)
                        }
                        .frame(height: totalHeight)
                }
                .zIndex(1)

        case .blockContinuation:
            Color.clear
        }
    }

    private enum CellRole {
        case empty
        case blockStart(SnapshotCourse, spanCount: Int)
        case blockContinuation
    }

    private func buildLookup() -> [Int: [String: SnapshotCourse]] {
        var lookup: [Int: [String: SnapshotCourse]] = [:]
        for course in snapshot.courses {
            for (weekday, ids) in course.schedule {
                for periodId in ids {
                    lookup[weekday, default: [:]][periodId] = course
                }
            }
        }
        return lookup
    }

    private func cellRole(
        weekday: Int,
        periodIndex: Int,
        periods: [String],
        lookup: [Int: [String: SnapshotCourse]]
    ) -> CellRole {
        guard periodIndex >= 0, periodIndex < periods.count else { return .empty }
        let periodId = periods[periodIndex]
        guard let course = lookup[weekday]?[periodId] else { return .empty }

        if periodIndex > 0 {
            let prevId = periods[periodIndex - 1]
            if let prev = lookup[weekday]?[prevId], prev.courseNo == course.courseNo {
                return .blockContinuation
            }
        }

        var span = 1
        var nextIdx = periodIndex + 1
        while nextIdx < periods.count {
            let nextId = periods[nextIdx]
            if let next = lookup[weekday]?[nextId], next.courseNo == course.courseNo {
                span += 1
                nextIdx += 1
            } else {
                break
            }
        }
        return .blockStart(course, spanCount: span)
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
