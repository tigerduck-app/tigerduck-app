import SwiftUI

struct TimetableGridView: View {
    let viewModel: ClassTableViewModel

    private let cellHeight: CGFloat = 52
    private let headerHeight: CGFloat = 36
    private let periodWidth: CGFloat = 10

    private var weekdayLabels: [String] {
        viewModel.activeWeekdays.map { day in
            switch day {
            case 1: "一"
            case 2: "二"
            case 3: "三"
            case 4: "四"
            case 5: "五"
            case 6: "六"
            case 7: "日"
            default: ""
            }
        }
    }

    var body: some View {
        VStack(spacing: 3) {
            // Header row
            HStack(spacing: 3) {
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
            ForEach(viewModel.activePeriods) { period in
                HStack(spacing: 3) {
                    // Period label
                    Text(period.displayLabel)
                        .font(TigerDuckTheme.Typography.caption2)
                        .foregroundStyle(Color.textSecondary)
                        .frame(width: periodWidth, height: cellHeight)

                    // Day cells
                    ForEach(viewModel.activeWeekdays, id: \.self) { weekday in
                        TimetableCellView(
                            course: viewModel.course(for: weekday, period: period.id),
                            hasBadge: {
                                guard let c = viewModel.course(for: weekday, period: period.id) else { return false }
                                return viewModel.hasAssignment(for: c.courseNo)
                            }(),
                            onTap: {
                                if let c = viewModel.course(for: weekday, period: period.id) {
                                    viewModel.selectCourse(c, weekday: weekday, periodId: period.id)
                                }
                            }
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: cellHeight)
                    }
                }
            }
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.sm)
    }
}
