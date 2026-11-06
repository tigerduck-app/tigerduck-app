import SwiftUI
import TigerDuckCore
import WidgetKit

struct WeekGridView: View {
    let snapshot: WidgetSnapshot
    let now: Date
    let palette: WidgetPalette
    let family: WidgetFamily

    private let spacing: CGFloat = 2

    @ScaledMetric(relativeTo: .caption2) private var textSize: CGFloat = 11
    @ScaledMetric(relativeTo: .caption2) private var headerHeight: CGFloat = 18

    private var datesBelowWeekdays: Bool { family.isExtraLargePortrait }
    private var size: CGFloat { family == .systemLarge ? textSize : textSize + 1 }
    private var radius: CGFloat { family == .systemLarge ? 5 : 7 }

    var body: some View {
        Group {
            if !snapshot.isLoggedIn {
                TodayMessage(key: "widget_sign_in", palette: palette)
            } else {
                grid
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private var grid: some View {
        let weekdays = snapshot.activeWeekdays
        let periods = snapshot.activePeriodIds
        let header = datesBelowWeekdays ? headerHeight * 1.9 : headerHeight
        let ongoing = Dictionary(
            WidgetDayLayout.rows(snapshot: snapshot, on: now, now: now).compactMap { item in
                item.progress.map { ("\(item.row.course.courseNo)-\(item.row.periods[0])", $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        return GeometryReader { geometry in
            let available = geometry.size.height - header - CGFloat(periods.count) * spacing
            let cellHeight = periods.isEmpty ? 0 : max(6, available / CGFloat(periods.count))
            let periodWidth = size * 1.4
            ZStack(alignment: .top) {
                VStack(spacing: spacing) {
                    Color.clear.frame(height: header)
                    ForEach(periods.indices, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(index.isMultiple(of: 2) ? Color.clear : palette.onSurfaceVariant.opacity(palette.isDark ? 0.12 : 0.06))
                            .frame(height: cellHeight)
                    }
                }
                VStack(spacing: spacing) {
                    WeekHeaderRow(
                        snapshot: snapshot, now: now, palette: palette, family: family, size: size,
                        periodWidth: periodWidth, height: header, spacing: spacing
                    )
                    ForEach(Array(periods.enumerated()), id: \.offset) { periodIndex, periodId in
                        HStack(spacing: spacing) {
                            Text(periodId)
                                .font(.system(size: size, weight: .semibold))
                                .foregroundStyle(palette.onSurfaceVariant)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                                .frame(width: periodWidth, height: cellHeight)
                            ForEach(weekdays, id: \.self) { weekday in
                                cell(weekday: weekday, periodIndex: periodIndex, periods: periods, cellHeight: cellHeight, ongoing: ongoing)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: cellHeight)
                            }
                        }
                        .zIndex(Double(periods.count - periodIndex))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cell(
        weekday: Int, periodIndex: Int, periods: [String], cellHeight: CGFloat, ongoing: [String: Double]
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
        case .empty, .skip:
            Color.clear

        case let .solo(course, spanCount):
            let block = Array(periods[periodIndex..<min(periodIndex + spanCount, periods.count)])
            let change = course.change(on: dayKey(of: weekday), startingAt: block.first)
            let isToday = weekday == ClassTimeline.weekday(of: now)
            WeekCourseBlock(
                course: course,
                classroom: change?.room ?? course.classroom(weekday: weekday, periods: block),
                change: change,
                progress: isToday ? ongoing["\(course.courseNo)-\(block[0])"] : nil,
                palette: palette, family: family, size: size, radius: radius
            )
            .frame(height: height(of: spanCount, cellHeight), alignment: .top)
            .frame(height: cellHeight, alignment: .top)

        case let .conflictStart(courseA, spanA, offsetA, courseB, spanB, offsetB, combinedSpan):
            HStack(spacing: 1) {
                conflictColumn(courseA, span: spanA, offset: offsetA, combinedSpan: combinedSpan, cellHeight: cellHeight)
                conflictColumn(courseB, span: spanB, offset: offsetB, combinedSpan: combinedSpan, cellHeight: cellHeight)
            }
            .frame(height: height(of: combinedSpan, cellHeight), alignment: .top)
            .frame(height: cellHeight, alignment: .top)

        case let .conflictMany(segments, combinedSpan, laneCount):
            HStack(spacing: 1) {
                ForEach(0..<laneCount, id: \.self) { lane in
                    ZStack(alignment: .top) {
                        ForEach(segments.filter { $0.lane == lane }) { segment in
                            conflictColumn(
                                segment.course, span: segment.span, offset: segment.offset,
                                combinedSpan: combinedSpan, cellHeight: cellHeight
                            )
                        }
                    }
                }
            }
            .frame(height: height(of: combinedSpan, cellHeight), alignment: .top)
            .frame(height: cellHeight, alignment: .top)
        }
    }

    private func height(of rows: Int, _ cellHeight: CGFloat) -> CGFloat {
        CGFloat(rows) * cellHeight + CGFloat(max(rows - 1, 0)) * spacing
    }

    /// The week runs from today, as the app's class table does, so each column has one date.
    static func day(of weekday: Int, from now: Date) -> Date {
        let ahead = (weekday - ClassTimeline.weekday(of: now) + 7) % 7
        return TaipeiTime.calendar.date(byAdding: .day, value: ahead, to: now) ?? now
    }

    private func dayKey(of weekday: Int) -> String {
        WidgetTimelineDerivation.dateKey(for: Self.day(of: weekday, from: now))
    }

    private func conflictColumn(
        _ course: SnapshotCourse, span: Int, offset: Int, combinedSpan: Int, cellHeight: CGFloat
    ) -> some View {
        let tile = palette.tile(course.colorHex)
        let top = offset > 0 ? height(of: offset, cellHeight) + spacing : 0
        return Text(course.displayName)
            .font(.courseName(size - 1, weight: .medium))
            .foregroundStyle(tile.ink)
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.55)
            .padding(1)
            .frame(maxWidth: .infinity)
            .frame(height: height(of: span, cellHeight))
            .classTile(tile, radius: radius, progress: nil, outline: 0, bottomBar: false)
            .padding(.top, top)
            .frame(height: height(of: combinedSpan, cellHeight), alignment: .top)
    }
}
