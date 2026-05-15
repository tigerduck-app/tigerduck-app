import SwiftUI

struct TimetableGridView: View {
    let viewModel: ClassTableViewModel

    private let cellHeight: CGFloat = 52
    private let rowSpacing: CGFloat = 3
    private let colSpacing: CGFloat = 3
    private let headerHeight: CGFloat = 30
    private let periodWidth: CGFloat = 12

    private static let allWeekdayLabels = AppConstants.Periods.weekdays + AppConstants.Periods.weekendDays

    private var weekdayLabels: [String] {
        viewModel.activeWeekdays.map { day in
            Self.allWeekdayLabels[safe: day - 1] ?? ""
        }
    }

    var body: some View {
        VStack(spacing: rowSpacing) {
            // Header row
            HStack(spacing: colSpacing) {
                Text("")
                    .frame(width: periodWidth, height: headerHeight)
                ForEach(Array(weekdayLabels.enumerated()), id: \.offset) { _, label in
                    Text(label)
                        .font(TigerDuckTheme.Typography.caption.bold())
                        .foregroundStyle(Color.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: headerHeight)
                }
            }

            // Grid rows
            ForEach(Array(viewModel.activePeriods.enumerated()), id: \.element.id) { periodIndex, period in
                HStack(spacing: colSpacing) {
                    // Period label
                    Text(period.displayLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(width: periodWidth, height: cellHeight)

                    // Day cells
                    ForEach(viewModel.activeWeekdays, id: \.self) { weekday in
                        cellView(weekday: weekday, periodIndex: periodIndex, periodId: period.id)
                            .frame(maxWidth: .infinity)
                            .frame(height: cellHeight)
                    }
                }
            }
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.xs)
    }

    @ViewBuilder
    private func cellView(weekday: Int, periodIndex: Int, periodId: String) -> some View {
        switch viewModel.cellRole(weekday: weekday, periodIndex: periodIndex) {
        case .empty:
            RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.sm)
                .fill(Color.cardSurface.opacity(0.15))

        case .blockStart(let course, let spanCount):
            let hasBadge = viewModel.hasAssignment(for: course.courseNo)
            let totalHeight = CGFloat(spanCount) * cellHeight + CGFloat(spanCount - 1) * rowSpacing

            Color.clear
                .overlay(alignment: .top) {
                    Button {
                        viewModel.selectCourse(course, weekday: weekday, periodId: periodId)
                    } label: {
                        RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.sm)
                            .fill(course.color.opacity(0.25))
                            .overlay {
                                RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.sm)
                                    .strokeBorder(course.color.opacity(0.4), lineWidth: 1)
                            }
                            .overlay {
                                Text(course.displayName)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Color.textPrimary)
                                    .lineLimit(spanCount > 1 ? 3 : 2)
                                    .multilineTextAlignment(.center)
                                    .padding(2)
                            }
                            .assignmentBadge(show: hasBadge, iconSize: 8, padding: 4)
                            .frame(height: totalHeight)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            viewModel.startRename(course)
                        } label: {
                            Label(String(localized: "class_table_rename_title"), systemImage: "pencil")
                        }
                        Button {
                            viewModel.startRecolor(course)
                        } label: {
                            Label(String(localized: "course_color_picker_title"), systemImage: "paintpalette")
                        }
                        Button(role: .destructive) {
                            viewModel.deleteCourse(course)
                        } label: {
                            Label(String(localized: "class_table_delete"), systemImage: "trash")
                        }
                    }
                }
                .zIndex(1)

        case .blockContinuation:
            Color.clear
        }
    }
}
