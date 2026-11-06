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
    /// Off for the export, which shares the plain timetable without today's date, week or changes.
    var showsThisWeek = true
    var switchCount = 0
    var onSwitch: ((_ before: TimetableRowTops, _ after: TimetableRowTops) -> Void)? = nil
    @Environment(AppEnvironment.self) private var app

    static let columnSpacing: CGFloat = 3
    private let rowSpacing: CGFloat = 3

    @ScaledMetric(relativeTo: .caption2) private var scaledCellHeight: CGFloat = 40
    private var periodColumn = TimetablePeriodColumn()
    @ScaledMetric(relativeTo: .caption2) private var periodTimeSize: CGFloat = 9
    @ScaledMetric(relativeTo: .caption2) private var periodLabelSize: CGFloat = 12

    private var policy: VisualStylePolicy { app.preferences.visualStylePolicy }
    private var drawsPeriodTiles: Bool { policy.classTableGridStyle == .periodTiles }

    private var cellHeight: CGFloat { max(52, scaledCellHeight) }
    private var periodWidth: CGFloat { periodColumn.width(drawsPeriodTiles: drawsPeriodTiles) }
    @ScaledMetric(relativeTo: .caption2) private var badgeIconSize: CGFloat = 8
    @ScaledMetric(relativeTo: .caption2) private var courseNameBaseSize: CGFloat = 8

    private var metrics: TimetableCellMetrics {
        TimetableCellMetrics(
            cellHeight: cellHeight, rowSpacing: rowSpacing,
            courseNameSize: courseNameBaseSize * CGFloat(CourseCardFontScale.renderScale(app.preferences.courseCardFontScale)),
            badgeIconSize: badgeIconSize
        )
    }

    var body: some View {
        TimelineView(.everyMinute) { _ in
            let _ = AppClockState.shared.version
            grid(now: AppClock.now())
        }
    }

    private func grid(now: Date) -> some View {
        let withClubs = showsThisWeek
        let weekdays = viewModel.grid.activeWeekdays(withClubs: withClubs)
        let periods = viewModel.grid.activePeriods(withClubs: withClubs)
        let firstRowTop = TimetableHeaderRow.height + rowSpacing
        let rowPitch = cellHeight + rowSpacing
        let switchCount = switchCount
        let thisWeek = showsThisWeek && viewModel.showsThisWeek
        let today = thisWeek ? now.scheduleWeekday : nil
        let week = showsThisWeek ? SchoolCalendar.week(of: viewModel.currentSemester, on: now) : nil
        return VStack(spacing: rowSpacing) {
            TimetableHeaderRow(weekdays: weekdays, today: today, week: week, drawsPeriodTiles: drawsPeriodTiles)

            ForEach(Array(periods.enumerated()), id: \.element.id) { periodIndex, period in
                Self.columns(weekdays, periodWidth: periodWidth) {
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
                        metrics: metrics, withClubs: withClubs
                    )
                        .frame(height: cellHeight)
                        .animation(.linear(duration: 0.25), value: key)
                }
            }
        }
        .overlay(alignment: .topLeading) {
            if withClubs, !viewModel.grid.clubs.isEmpty {
                Self.columns(weekdays, periodWidth: periodWidth) {
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
                    .padding(.leading, periodWidth + Self.columnSpacing)
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

    static func columns<Leading: View, Cell: View>(
        _ weekdays: [Int], periodWidth: CGFloat,
        @ViewBuilder leading: () -> Leading, @ViewBuilder cell: @escaping (Int) -> Cell
    ) -> some View {
        HStack(spacing: columnSpacing) {
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

/// The period column's width: a tile holds the period's number alone, otherwise its start and end
/// times sit around it.
struct TimetablePeriodColumn: DynamicProperty {
    @ScaledMetric(relativeTo: .caption2) private var timesWidth: CGFloat = 28
    @ScaledMetric(relativeTo: .caption2) private var numberWidth: CGFloat = 16

    func width(drawsPeriodTiles: Bool) -> CGFloat {
        drawsPeriodTiles ? max(20, numberWidth) : max(36, timesWidth)
    }
}

/// The weekday names over the grid's columns, and the shown term's week over its period numbers.
struct TimetableHeaderRow: View {
    static let height: CGFloat = 30
    static let font = TigerDuckTheme.Typography.caption.bold()
    /// At the largest text size on a 375 pt screen, seven English weekday names need about 0.4.
    static let minimumScale: CGFloat = 0.35
    private static let weekdayLabels = AppConstants.Periods.weekdays + AppConstants.Periods.weekendDays

    let weekdays: [Int]
    let today: Int?
    let week: Int?
    let drawsPeriodTiles: Bool
    private var periodColumn = TimetablePeriodColumn()

    var body: some View {
        TimetableHeaderLayout(periodWidth: periodColumn.width(drawsPeriodTiles: drawsPeriodTiles)) {
            if let week {
                label("W\(week)", style: Color.textSecondary)
                    .accessibilityLabel(Text(String(format: String(localized: "a11y_class_table_week"), week)))
            } else {
                Text("")
            }
            ForEach(weekdays, id: \.self) { weekday in
                label(name(of: weekday), style: weekday == today ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.textSecondary))
            }
        }
        .frame(height: Self.height)
    }

    private func name(of weekday: Int) -> String {
        Self.weekdayLabels[safe: weekday - 1] ?? ""
    }

    private func label(_ text: String, style: some ShapeStyle) -> some View {
        Text(text)
            .font(Self.font)
            .foregroundStyle(style)
            .lineLimit(1)
            .minimumScaleFactor(Self.minimumScale)
    }
}

/// The header's labels on the grid's columns: the week, the first subview, over the period column,
/// then a weekday name a column. The names shrink by the one scale the widest needs to fit its
/// column, and the week by that scale or by less if the period column is narrower, so the row
/// reads in one size. No label is given a height, since a minimum scale factor would shrink it to
/// fit the row's 30 pt.
private struct TimetableHeaderLayout: Layout {
    let periodWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let ideal = sizes.dropFirst().reduce(periodWidth) { $0 + TimetableGridView.columnSpacing + $1.width }
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? ideal
        return CGSize(width: width, height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let week = subviews.first else { return }
        let spacing = TimetableGridView.columnSpacing
        let names = subviews.dropFirst()
        let columnWidth = (bounds.width - periodWidth) / CGFloat(max(names.count, 1)) - spacing
        let widths = subviews.map { $0.sizeThatFits(.unspecified).width }
        let scale = min(1, columnWidth / max(widths.dropFirst().max() ?? 0, 1))
        place(week, width: widths[0] * min(scale, periodWidth / max(widths[0], 1)), midX: bounds.minX + periodWidth / 2, in: bounds)
        for (index, name) in names.enumerated() {
            let midX = bounds.minX + periodWidth + spacing + columnWidth / 2 + CGFloat(index) * (columnWidth + spacing)
            place(name, width: widths[index + 1] * scale, midX: midX, in: bounds)
        }
    }

    private func place(_ label: LayoutSubview, width: CGFloat, midX: CGFloat, in bounds: CGRect) {
        label.place(at: CGPoint(x: midX, y: bounds.midY), anchor: .center, proposal: ProposedViewSize(width: width, height: nil))
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
