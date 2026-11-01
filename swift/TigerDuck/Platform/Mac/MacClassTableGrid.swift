#if os(macOS)
import SwiftUI
import TigerDuckCore

struct MacClassTableGrid: View {
    let viewModel: ClassTableViewModel

    @Environment(AppEnvironment.self) private var app

    private let cellHeight: CGFloat = 56
    private let rowSpacing: CGFloat = 4
    private let periodLabelWidth: CGFloat = 56

    private var periods: [String] { viewModel.grid.activePeriods.map(\.id) }

    var body: some View {
        VStack(spacing: rowSpacing) {
            headerRow
            HStack(alignment: .top, spacing: rowSpacing) {
                periodLabelColumn
                ForEach(viewModel.grid.activeWeekdays, id: \.self) { weekday in
                    weekdayColumn(weekday)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.lg, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.lg, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 4)
    }

    private var headerRow: some View {
        HStack(spacing: rowSpacing) {
            Color.clear.frame(width: periodLabelWidth, height: 22)
            ForEach(viewModel.grid.activeWeekdays, id: \.self) { weekday in
                Text(weekdayLabel(weekday))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func weekdayLabel(_ weekday: Int) -> String {
        switch weekday {
        case 1...5: return AppConstants.Periods.weekdays[safe: weekday - 1] ?? "?"
        case 6: return AppConstants.Periods.weekendDays[safe: 0] ?? "?"
        case 7: return AppConstants.Periods.weekendDays[safe: 1] ?? "?"
        default: return "?"
        }
    }

    private var periodLabelColumn: some View {
        VStack(spacing: rowSpacing) {
            ForEach(periods, id: \.self) { period in
                periodLabel(period)
                    .frame(height: cellHeight)
            }
        }
        .frame(width: periodLabelWidth)
    }

    private func periodLabel(_ period: String) -> some View {
        let times = AppConstants.PeriodTimes.mapping[period]
        return VStack(alignment: .trailing, spacing: 2) {
            if let times {
                Text(times.start)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Text(period)
                .font(.subheadline.weight(.semibold))
            if let times {
                Text(times.end)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 4)
    }

    @ViewBuilder
    private func weekdayColumn(_ weekday: Int) -> some View {
        let periods = self.periods
        VStack(spacing: rowSpacing) {
            ForEach(periods.indices, id: \.self) { index in
                let role = viewModel.grid.cellRole(weekday: weekday, periodIndex: index)
                cellView(role: role, weekday: weekday, periods: periods, index: index)
            }
        }
    }

    @ViewBuilder
    private func cellView(role: ClassTableGrid.CellRole, weekday: Int, periods: [String], index: Int) -> some View {
        let periodId = periods[index]
        switch role {
        case .empty:
            emptyCell.frame(height: cellHeight)
        case let .solo(course, spanCount):
            MacClassTableCourseCell(
                viewModel: viewModel, course: course, roomHint: roomHint(course, weekday: weekday, periodId: periodId)
            )
                .frame(height: blockHeight(spanCount))
                .onTapGesture { viewModel.selectCourse(course, weekday: weekday, periodId: periodId) }
        case let .conflictStart(a, spanA, offsetA, b, spanB, offsetB, combinedSpan):
            HStack(spacing: rowSpacing) {
                conflictColumn(
                    course: a, span: spanA, offset: offsetA, combinedSpan: combinedSpan,
                    weekday: weekday, periodId: periods[index + offsetA]
                )
                conflictColumn(
                    course: b, span: spanB, offset: offsetB, combinedSpan: combinedSpan,
                    weekday: weekday, periodId: periods[index + offsetB]
                )
            }
            .frame(height: blockHeight(combinedSpan))
        case let .conflictMany(segments, combinedSpan, laneCount):
            HStack(spacing: rowSpacing) {
                ForEach(0..<laneCount, id: \.self) { lane in
                    ZStack(alignment: .top) {
                        ForEach(segments.filter { $0.lane == lane }) { segment in
                            conflictColumn(
                                course: segment.course,
                                span: segment.span,
                                offset: segment.offset,
                                combinedSpan: combinedSpan,
                                weekday: weekday,
                                periodId: periods[index + segment.offset]
                            )
                        }
                    }
                }
            }
            .frame(height: blockHeight(combinedSpan))
        case .skip:
            EmptyView()
        }
    }

    private func roomHint(_ course: CourseStore.Course, weekday: Int, periodId: String) -> String? {
        guard app.preferences.showClassroomInClassTable else { return nil }
        return CourseRoomHint.room(for: course, weekday: weekday, periodId: periodId)
    }

    private func blockHeight(_ span: Int) -> CGFloat {
        CGFloat(span) * cellHeight + CGFloat(max(span - 1, 0)) * rowSpacing
    }

    @ViewBuilder
    private func conflictColumn(
        course: CourseStore.Course, span: Int, offset: Int, combinedSpan: Int, weekday: Int, periodId: String
    ) -> some View {
        let bottom = max(combinedSpan - offset - span, 0)
        let ignored = viewModel.editor.ignoresAssignments(of: course.courseNo)
        VStack(spacing: rowSpacing) {
            if offset > 0 {
                Color.clear.frame(height: blockHeight(offset))
            }
            MacClassTableCourseCell(viewModel: viewModel, course: course)
                .frame(height: blockHeight(span))
                .onTapGesture { viewModel.selectCourse(course, weekday: weekday, periodId: periodId) }
                .accessibilityLabel(Text(MacClassTableCourseCell.spokenName(course, ignoresAssignments: ignored)))
            if bottom > 0 {
                Color.clear.frame(height: blockHeight(bottom))
            }
        }
    }

    private var emptyCell: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.04), lineWidth: 0.5)
            )
    }
}
#endif
