import SwiftUI
import TigerDuckCore

struct WeekGridView: View {
    let snapshot: WidgetSnapshot
    let now: Date
    let palette: WidgetPalette

    private let rowSpacing: CGFloat = 2
    private let colSpacing: CGFloat = 2
    private let headerHeight: CGFloat = 18
    private let periodWidth: CGFloat = 12
    private let cornerRadius: CGFloat = 4

    private let userCourseNameScale: CGFloat = CGFloat(CourseCardFontScale.renderScale(CourseCardFontScaleStore().read()))

    @ScaledMetric(relativeTo: .caption2) private var soloCourseNameBase: CGFloat = 9
    @ScaledMetric(relativeTo: .caption2) private var conflictCourseNameBase: CGFloat = 8

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

        GeometryReader { geom in
            let totalRowSpacing = CGFloat(max(0, periods.count - 1)) * rowSpacing
            let available = max(0, geom.size.height - headerHeight - rowSpacing - totalRowSpacing)
            let minCellHeight: CGFloat = 6
            let computed = periods.isEmpty ? 0 : available / CGFloat(periods.count)
            let cellHeight = periods.isEmpty ? 0 : max(minCellHeight, computed)
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
        cellHeight: CGFloat,
        fontScale: CGFloat
    ) -> some View {
        let role = ClassTableLayout.cellRole(
            courses: snapshot.courses,
            periodIds: periods,
            weekday: weekday,
            periodIndex: periodIndex,
            keyOf: { $0.courseNo },
            scheduleOf: { $0.schedule }
        )
        switch role {
        case .empty:
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(palette.emptyCell)

        case let .solo(course, spanCount):
            let block = Array(periods[periodIndex..<min(periodIndex + spanCount, periods.count)])
            let change = course.change(on: dayKey(of: weekday), startingAt: block.first)
            courseBlock(
                course,
                classroom: change?.room ?? course.classroom(weekday: weekday, periods: block),
                change: change,
                spanCount: spanCount,
                cellHeight: cellHeight,
                fontScale: fontScale
            )

        case let .conflictStart(courseA, spanA, offsetA, courseB, spanB, offsetB, combinedSpan):
            let totalHeight = CGFloat(combinedSpan) * cellHeight + CGFloat(combinedSpan - 1) * rowSpacing
            Color.clear
                .overlay(alignment: .top) {
                    HStack(spacing: 1) {
                        conflictColumn(courseA, span: spanA, offset: offsetA, combinedSpan: combinedSpan, cellHeight: cellHeight, fontScale: fontScale)
                        conflictColumn(courseB, span: spanB, offset: offsetB, combinedSpan: combinedSpan, cellHeight: cellHeight, fontScale: fontScale)
                    }
                    .frame(height: totalHeight)
                }
                .zIndex(1)

        case let .conflictMany(segments, combinedSpan, laneCount):
            let totalHeight = CGFloat(combinedSpan) * cellHeight + CGFloat(combinedSpan - 1) * rowSpacing
            Color.clear
                .overlay(alignment: .top) {
                    HStack(spacing: 1) {
                        ForEach(0..<laneCount, id: \.self) { lane in
                            ZStack(alignment: .top) {
                                ForEach(segments.filter { $0.lane == lane }) { segment in
                                    conflictColumn(
                                        segment.course,
                                        span: segment.span,
                                        offset: segment.offset,
                                        combinedSpan: combinedSpan,
                                        cellHeight: cellHeight,
                                        fontScale: fontScale
                                    )
                                }
                            }
                        }
                    }
                    .frame(height: totalHeight)
                }
                .zIndex(1)

        case .skip:
            Color.clear
        }
    }

    /// The week runs from today, as the app's class table does, so each column has one date.
    private func dayKey(of weekday: Int) -> String {
        let ahead = (weekday - WidgetTimelineDerivation.weekdayFor(now) + 7) % 7
        let day = TaipeiTime.calendar.date(byAdding: .day, value: ahead, to: now) ?? now
        return WidgetTimelineDerivation.dateKey(for: day)
    }

    @ViewBuilder
    private func courseBlock(
        _ course: SnapshotCourse, classroom: String, change: SnapshotCourseChange?,
        spanCount: Int, cellHeight: CGFloat, fontScale: CGFloat
    ) -> some View {
        let totalHeight = CGFloat(spanCount) * cellHeight + CGFloat(spanCount - 1) * rowSpacing
        let courseColor = Color(widgetHex: course.colorHex)
        let isCancelled = change?.cancelled == true
        Color.clear
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(courseColor.opacity(isCancelled ? 0.1 : 0.25))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .strokeBorder(courseColor.opacity(0.4), lineWidth: 0.5)
                    }
                    .overlay {
                        VStack(spacing: 1) {
                            if !isCancelled, spanCount > 1, let time = Self.changedTime(change) {
                                Label(time, systemImage: "clock.fill")
                                    .labelStyle(ChangedValueLabelStyle())
                                    .font(.system(size: 7 * fontScale, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(palette.changeInk)
                                    .lineLimit(1)
                            }
                            Text(course.displayName)
                                .font(.system(size: soloCourseNameBase * fontScale * userCourseNameScale, weight: .medium))
                                .strikethrough(isCancelled)
                                .foregroundStyle(isCancelled ? palette.onSurfaceVariant : palette.onSurface)
                                .lineLimit(spanCount > 1 ? 3 : 2)
                                .multilineTextAlignment(.center)
                                .minimumScaleFactor(0.7)
                            if isCancelled, spanCount > 1 {
                                Text(String(localized: "course_card_cancelled"))
                                    .font(.system(size: 7 * fontScale, weight: .semibold))
                                    .foregroundStyle(palette.onSurfaceVariant)
                                    .lineLimit(1)
                            } else if change?.room != nil, spanCount > 1 {
                                Label(classroom, systemImage: "arrow.left.arrow.right")
                                    .labelStyle(ChangedValueLabelStyle())
                                    .font(.system(size: 7 * fontScale, weight: .semibold))
                                    .foregroundStyle(palette.changeInk)
                                    .lineLimit(1)
                            } else if !classroom.isEmpty && spanCount > 1 {
                                Text(classroom)
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
    }

    private static func changedTime(_ change: SnapshotCourseChange?) -> String? {
        switch (change?.start, change?.end) {
        case let (start?, end?): "\(start)–\(end)"
        case let (start?, nil): start
        case let (nil, end?): "–\(end)"
        case (nil, nil): nil
        }
    }

    @ViewBuilder
    private func conflictColumn(
        _ course: SnapshotCourse,
        span: Int,
        offset: Int,
        combinedSpan: Int,
        cellHeight: CGFloat,
        fontScale: CGFloat
    ) -> some View {
        let topRows = offset
        let bottomRows = max(combinedSpan - offset - span, 0)
        let topHeight = topRows > 0
            ? CGFloat(topRows) * cellHeight + CGFloat(topRows - 1) * rowSpacing
            : 0
        let bottomHeight = bottomRows > 0
            ? CGFloat(bottomRows) * cellHeight + CGFloat(bottomRows - 1) * rowSpacing
            : 0
        let courseHeight = CGFloat(span) * cellHeight + CGFloat(max(span - 1, 0)) * rowSpacing
        VStack(spacing: rowSpacing) {
            if topRows > 0 {
                Color.clear.frame(height: topHeight)
            }
            conflictHalf(course, fontScale: fontScale)
                .frame(height: courseHeight)
            if bottomRows > 0 {
                Color.clear.frame(height: bottomHeight)
            }
        }
    }

    @ViewBuilder
    private func conflictHalf(_ course: SnapshotCourse, fontScale: CGFloat) -> some View {
        let courseColor = Color(widgetHex: course.colorHex)
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(courseColor.opacity(0.25))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(courseColor.opacity(0.4), lineWidth: 0.5)
            }
            .overlay {
                Text(course.displayName)
                    .font(.system(size: conflictCourseNameBase * fontScale * userCourseNameScale, weight: .medium))
                    .foregroundStyle(palette.onSurface)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.55)
                    .padding(1)
            }
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
