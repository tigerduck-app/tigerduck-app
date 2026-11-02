import Defaults
import SwiftUI
import TigerDuckCore

nonisolated struct TimetableRowTops: Equatable, Sendable {
    var switchCount: Int
    var tops: [String: CGFloat]

    static func shift(from before: Self, to after: Self, visibleTop: CGFloat) -> CGFloat {
        let moves = before.tops.compactMap { id, top in after.tops[id].map { (from: top, to: $0) } }
        let row = moves.filter { $0.from >= visibleTop }.min { $0.from < $1.from }
            ?? moves.max { $0.from < $1.from }
        return row.map { $0.to - $0.from } ?? 0
    }
}

struct TimetableGridView: View {
    let viewModel: ClassTableViewModel
    var showsAssignmentBadges = true
    var differentiateWithoutColor: Bool? = nil
    /// Off for the export, which shares the plain timetable without today's date or changes.
    var showsThisWeek = true
    var switchCount = 0
    var onSwitch: ((_ before: TimetableRowTops, _ after: TimetableRowTops) -> Void)? = nil
    @Environment(AppEnvironment.self) private var app

    private let rowSpacing: CGFloat = 3
    private let colSpacing: CGFloat = 3
    private let headerHeight: CGFloat = 30

    @ScaledMetric(relativeTo: .caption2) private var scaledCellHeight: CGFloat = 40
    @ScaledMetric(relativeTo: .caption2) private var scaledPeriodWidth: CGFloat = 28
    @ScaledMetric(relativeTo: .caption2) private var scaledPeriodNumberWidth: CGFloat = 16
    @ScaledMetric(relativeTo: .caption2) private var periodTimeSize: CGFloat = 9
    @ScaledMetric(relativeTo: .caption2) private var periodLabelSize: CGFloat = 12

    private var policy: VisualStylePolicy { app.preferences.visualStylePolicy }
    private var drawsPeriodTiles: Bool { policy.classTableGridStyle == .periodTiles }

    private var cellHeight: CGFloat { max(52, scaledCellHeight) }
    private var periodWidth: CGFloat {
        drawsPeriodTiles ? max(20, scaledPeriodNumberWidth) : max(36, scaledPeriodWidth)
    }
    @ScaledMetric(relativeTo: .caption2) private var badgeIconSize: CGFloat = 8
    @ScaledMetric(relativeTo: .caption2) private var courseNameBaseSize: CGFloat = 8

    private var metrics: TimetableCellMetrics {
        TimetableCellMetrics(
            cellHeight: cellHeight, rowSpacing: rowSpacing,
            courseNameSize: courseNameBaseSize * CGFloat(CourseCardFontScale.renderScale(app.preferences.courseCardFontScale)),
            badgeIconSize: badgeIconSize
        )
    }

    private static let allWeekdayLabels = AppConstants.Periods.weekdays + AppConstants.Periods.weekendDays

    var body: some View {
        TimelineView(.everyMinute) { _ in
            let _ = AppClockState.shared.version
            grid(now: AppClock.now())
        }
    }

    private func grid(now: Date) -> some View {
        // Clubs belong to this week's table, which the export does not show.
        let withClubs = showsThisWeek
        let weekdays = viewModel.grid.activeWeekdays(withClubs: withClubs)
        let periods = viewModel.grid.activePeriods(withClubs: withClubs)
        let firstRowTop = headerHeight + rowSpacing
        let rowPitch = cellHeight + rowSpacing
        let switchCount = switchCount
        let thisWeek = showsThisWeek && viewModel.showsThisWeek
        let today = thisWeek ? now.scheduleWeekday : nil
        return VStack(spacing: rowSpacing) {
            columns(weekdays) {
                Text("")
                    .frame(height: headerHeight)
            } cell: { weekday in
                Text(Self.allWeekdayLabels[safe: weekday - 1] ?? "")
                    .font(TigerDuckTheme.Typography.caption.bold())
                    .foregroundStyle(weekday == today ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.textSecondary))
                    .frame(height: headerHeight)
            }

            ForEach(Array(periods.enumerated()), id: \.element.id) { periodIndex, period in
                columns(weekdays) {
                    periodLabel(period)
                } cell: { weekday in
                    let role = viewModel.grid.cellRole(weekday: weekday, periodIndex: periodIndex, withClubs: withClubs)
                    let meeting = thisWeek ? changedMeeting(role, weekday: weekday, periodId: period.id, now: now) : nil
                    let key = TimetableCellTransitionID.of(
                        role, weekday: weekday, periodId: period.id, meeting: meeting,
                        showsRooms: app.preferences.showClassroomInClassTable
                    )
                    TimetableCell(
                        viewModel: viewModel, role: role, key: key, weekday: weekday, periodId: period.id,
                        meeting: meeting, showsAssignmentBadges: showsAssignmentBadges,
                        differentiateWithoutColor: differentiateWithoutColor, drawsPeriodTiles: drawsPeriodTiles,
                        metrics: metrics
                    )
                        .frame(height: cellHeight)
                        .animation(.linear(duration: 0.25), value: key)
                }
            }
        }
        .overlay(alignment: .topLeading) {
            if withClubs, !viewModel.grid.clubs.isEmpty {
                columns(weekdays) {
                    Color.clear
                } cell: { weekday in
                    TimetableClubColumn(
                        viewModel: viewModel, weekday: weekday, periods: periods, metrics: metrics,
                        drawsPeriodTiles: drawsPeriodTiles, policy: policy
                    )
                }
                .padding(.top, firstRowTop)
            }
        }
        .overlay(alignment: .topLeading) {
            if let today, weekdays.contains(today),
               let offset = TimetableNowLine.offset(
                   minute: TimetableNowLine.minuteOfDay(now), periods: periods.compactMap(\.minutes),
                   rowPitch: rowPitch, cellHeight: cellHeight
               ) {
                TimetableNowLine()
                    .padding(.leading, periodWidth + colSpacing)
                    .offset(y: firstRowTop + offset - TimetableNowLine.width / 2)
            }
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.xs)
        .background(alignment: .top) {
            if drawsPeriodTiles {
                VStack(spacing: 0) {
                    ForEach(periods.indices, id: \.self) { index in
                        (index.isMultiple(of: 2) ? Color.rowBand : Color.rowBandAlternate)
                            .frame(height: rowPitch)
                    }
                }
                .padding(.top, firstRowTop - rowSpacing / 2)
            }
        }
        .onChange(of: TaipeiTime.dayKey(for: now)) {
            viewModel.refreshClubs(now: now)
        }
        .onGeometryChange(for: TimetableRowTops.self) { proxy in
            let gridTop = proxy.frame(in: .scrollView).minY
            return TimetableRowTops(switchCount: switchCount, tops: Dictionary(
                uniqueKeysWithValues: periods.enumerated().map { index, period in
                    (period.id, gridTop + firstRowTop + CGFloat(index) * rowPitch)
                }
            ))
        } action: { before, after in
            if before.switchCount != after.switchCount { onSwitch?(before, after) }
        }
    }

    /// The period labels' column, then one column of equal width per weekday.
    private func columns<Leading: View, Cell: View>(
        _ weekdays: [Int], @ViewBuilder leading: () -> Leading, @ViewBuilder cell: @escaping (Int) -> Cell
    ) -> some View {
        HStack(spacing: colSpacing) {
            leading()
                .frame(width: periodWidth)
            ForEach(weekdays, id: \.self) { weekday in
                cell(weekday)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func periodLabel(_ period: TimetablePeriod) -> some View {
    VStack(spacing: 0) {
        if !drawsPeriodTiles {
            Text(period.startTime)
                .font(.system(size: periodTimeSize))
                .foregroundStyle(Color.textSecondary)
        }
        Text(period.displayLabel)
            .font(.system(size: periodLabelSize, weight: .bold))
            .foregroundStyle(Color.textPrimary)
        if !drawsPeriodTiles {
            Text(period.endTime)
                .font(.system(size: periodTimeSize))
                .foregroundStyle(Color.textSecondary)
        }
    }
    .lineLimit(1)
    .minimumScaleFactor(0.7)
    .frame(width: periodWidth, height: cellHeight)
    }

    private func changedMeeting(
        _ role: ClassTableGrid.CellRole, weekday: Int, periodId: String, now: Date
    ) -> CourseTimeSlot? {
        // A conflict cell lays its courses out in lanes by their timetable spans, which a changed
        // time would break, so conflicting courses keep the weekly look.
        guard case .solo(let course, _) = role else { return nil }
        return viewModel.changedMeeting(of: course, weekday: weekday, at: periodId, today: now)
    }

}

enum TimetableCellTransitionID {
    static func of(
        _ role: ClassTableGrid.CellRole, weekday: Int, periodId: String, meeting: CourseTimeSlot?, showsRooms: Bool
    ) -> String {
        func shown(_ course: CourseStore.Course) -> String { "\(course.courseNo)|\(course.displayName)" }
        switch role {
        case .empty:
            return "empty"
        case .skip:
            return "skip"
        case .solo(let course, let spanCount):
            let room = showsRooms
                ? CourseRoomHint.room(for: course, weekday: weekday, periodId: periodId) ?? ""
                : ""
            let change = meeting.map { "\($0.isCancelled)|\($0.room)|\($0.start)|\($0.end)|\($0.notes.count)" } ?? ""
            return "solo \(spanCount) \(shown(course))|\(room)|\(change)"
        case let .conflictStart(courseA, spanA, offsetA, courseB, spanB, offsetB, combinedSpan):
            return "pair \(combinedSpan) \(spanA) \(offsetA) \(shown(courseA)) \(spanB) \(offsetB) \(shown(courseB))"
        case let .conflictMany(segments, combinedSpan, laneCount):
            let lanes = segments.map { "\($0.span) \($0.offset) \($0.lane) \(shown($0.course))" }
            return "lanes \(combinedSpan) \(laneCount) " + lanes.joined(separator: " ")
        }
    }
}
