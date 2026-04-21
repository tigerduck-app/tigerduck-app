import SwiftUI

/// Modal detail for a single course row. Reuses the ClassTable cache —
/// searched first by semester, then falling back to the user-added course
/// list — so returning users see instructor, enrollment, and schedule
/// metadata that the score-query HTML itself never exposes. Administrative
/// fields (status / credit type / delivery mode) have been dropped in favor
/// of this richer roster context.
struct ScoreCourseDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    let course: CourseGrade

    /// Resolved lazily from DataCache the first time the sheet renders. Nil
    /// means we have no roster record for this term — common for graduating
    /// seniors pulling years-old transcripts from before the class-table
    /// cache even existed.
    @State private var rosterCourse: SDCourse?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.lg) {
                    headerCard

                    if let rosterCourse {
                        rosterSection(rosterCourse)
                    } else {
                        unavailableCard
                    }

                    if !course.remark.isEmpty {
                        remarkSection
                    }
                }
                .padding(TigerDuckTheme.Spacing.lg)
            }
            .background(Color.backgroundPrimary)
            .navigationTitle(course.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .onAppear(perform: resolveRosterCourse)
    }

    // MARK: - Header

    private var headerCard: some View {
        HStack(alignment: .center, spacing: TigerDuckTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text(course.name)
                    .font(TigerDuckTheme.Typography.title)
                    .foregroundStyle(Color.textPrimary)
                Text(course.code)
                    .font(TigerDuckTheme.Typography.caption.monospaced())
                    .foregroundStyle(Color.textSecondary)
                Text("\(displayTerm) · \(course.credits ?? 0) 學分")
                    .font(TigerDuckTheme.Typography.caption)
                    .foregroundStyle(Color.textSecondary)
            }
            Spacer()
            Text(gradeDisplay)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(gradeColor)
        }
        .padding(TigerDuckTheme.Spacing.md)
        .presetCard(policy: appState.visualStylePolicy)
    }

    // MARK: - Roster section

    @ViewBuilder
    private func rosterSection(_ roster: SDCourse) -> some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.sm) {
            SectionHeader(title: "課程資訊")
            VStack(spacing: 0) {
                if !roster.instructor.isEmpty {
                    metaRow(label: "授課教師", value: roster.instructor)
                    rowDivider
                }
                if roster.maxCount > 0 {
                    metaRow(
                        label: "修課人數",
                        value: "\(roster.enrolledCount) / \(roster.maxCount)"
                    )
                    rowDivider
                }
                let classroomText = SDCourse.dedup(roster.classroom)
                if !classroomText.isEmpty {
                    metaRow(label: "教室", value: classroomText)
                    rowDivider
                }
                if !roster.schedule.isEmpty {
                    ForEach(orderedScheduleLines(for: roster), id: \.self) { line in
                        metaRow(label: line.label, value: line.value)
                        if line != orderedScheduleLines(for: roster).last {
                            rowDivider
                        }
                    }
                }
            }
            .presetCard(policy: appState.visualStylePolicy)
        }
    }

    private var unavailableCard: some View {
        HStack(spacing: TigerDuckTheme.Spacing.sm) {
            Image(systemName: "tray")
                .foregroundStyle(Color.textSecondary)
            Text("目前沒有此課程的修課資料")
                .font(TigerDuckTheme.Typography.caption)
                .foregroundStyle(Color.textSecondary)
            Spacer()
        }
        .padding(TigerDuckTheme.Spacing.md)
        .presetCard(policy: appState.visualStylePolicy)
    }

    // MARK: - Remark

    private var remarkSection: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.sm) {
            SectionHeader(title: "備註")
            Text(course.remark)
                .font(TigerDuckTheme.Typography.body)
                .foregroundStyle(Color.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(TigerDuckTheme.Spacing.md)
                .presetCard(policy: appState.visualStylePolicy)
        }
    }

    // MARK: - Row primitives

    private func metaRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(TigerDuckTheme.Typography.body)
                .foregroundStyle(Color.textSecondary)
            Spacer()
            Text(value)
                .font(TigerDuckTheme.Typography.body)
                .foregroundStyle(Color.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.md)
        .padding(.vertical, TigerDuckTheme.Spacing.sm)
    }

    private var rowDivider: some View {
        Divider().background(Color.white.opacity(0.05))
    }

    // MARK: - Resolution

    private func resolveRosterCourse() {
        guard rosterCourse == nil else { return }
        let semesterMatches = DataCache.shared.loadCourses(semester: course.term)
        if let match = semesterMatches.first(where: { $0.courseNo == course.code }) {
            rosterCourse = match
            return
        }
        let userAdded = DataCache.shared.loadUserAddedCourses()
        if let match = userAdded.first(where: {
            $0.courseNo == course.code && ($0.semester == course.term || $0.semester.isEmpty)
        }) {
            rosterCourse = match
        }
    }

    // MARK: - Schedule formatting

    private struct ScheduleLine: Hashable {
        let label: String
        let value: String
    }

    /// Converts `SDCourse.schedule` into one row per weekday. Rows are sorted
    /// by weekday so the list reads Mon→Fri→weekend; periods are ordered by
    /// the canonical chronological order (accounting for A/B/C/D evening
    /// slots) and condensed into a single time range when they are
    /// contiguous.
    private func orderedScheduleLines(for roster: SDCourse) -> [ScheduleLine] {
        let order = AppConstants.Periods.chronologicalOrder
        let weekdayLabels = AppConstants.Periods.weekdays + AppConstants.Periods.weekendDays

        return roster.schedule
            .sorted { $0.key < $1.key }
            .compactMap { weekday, periods -> ScheduleLine? in
                guard weekday >= 1, weekday - 1 < weekdayLabels.count else { return nil }
                let sortedPeriods = periods.sorted {
                    (order.firstIndex(of: $0) ?? Int.max) <
                    (order.firstIndex(of: $1) ?? Int.max)
                }
                guard let first = sortedPeriods.first,
                      let last = sortedPeriods.last else { return nil }

                let label = "週\(weekdayLabels[weekday - 1])"
                let periodLabel = sortedPeriods.count == 1 ? first : "\(first)-\(last)"
                let timeRange = timeRange(from: first, to: last)
                let value = timeRange.isEmpty
                    ? "第 \(periodLabel) 節"
                    : "第 \(periodLabel) 節 · \(timeRange)"
                return ScheduleLine(label: label, value: value)
            }
    }

    private func timeRange(from firstPeriod: String, to lastPeriod: String) -> String {
        let mapping = AppConstants.PeriodTimes.mapping
        guard let startTime = mapping[firstPeriod]?.start,
              let endTime = mapping[lastPeriod]?.end else {
            return ""
        }
        return "\(startTime)-\(endTime)"
    }

    // MARK: - Display formatters

    private var displayTerm: String {
        guard course.term.count == 4 else { return course.term }
        let year = String(course.term.prefix(3))
        let sem = String(course.term.suffix(1))
        let label = sem == "1" ? "上學期" : sem == "2" ? "下學期" : sem
        return "\(year) \(label)"
    }

    private var gradeDisplay: String {
        switch course.status {
        case .pending:  return "未到"
        case .withdrew: return "退選"
        case .exempted: return "抵免"
        case .passed:   return course.grade.isEmpty ? "通過" : course.grade
        case .graded:   return course.grade
        case .unknown:  return course.grade.isEmpty ? "—" : course.grade
        }
    }

    private var gradeColor: Color {
        switch course.status {
        case .pending, .withdrew, .unknown:
            return Color.textSecondary
        case .exempted:
            return Color(hex: 0x85C1E9)
        case .passed:
            return course.grade == "不通過" ? Color(hex: 0xE74C3C) : Color(hex: 0x4ECDC4)
        case .graded:
            let upper = course.grade.uppercased()
            if upper.hasPrefix("A") { return Color(hex: 0x2ECC71) }
            if upper.hasPrefix("B") { return Color(hex: 0x3498DB) }
            if upper.hasPrefix("C") { return Color(hex: 0xF7DC6F) }
            if upper.hasPrefix("D") || upper.hasPrefix("E") || upper.hasPrefix("F") {
                return Color(hex: 0xFF6B6B)
            }
            return Color.textPrimary
        }
    }
}
