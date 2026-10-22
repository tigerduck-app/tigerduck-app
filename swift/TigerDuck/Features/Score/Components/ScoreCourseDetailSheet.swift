import SwiftUI

struct ScoreCourseDetailSheet: View {
    @Environment(AppState.self) private var appState

    let course: CourseGrade

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
                .padding(.vertical, TigerDuckTheme.Spacing.lg)
            }
            .background(Color.backgroundPrimary)
            .navigationTitle(course.name)
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear(perform: resolveRosterCourse)
    }

    private var headerCard: some View {
        HStack(alignment: .center, spacing: TigerDuckTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text(course.name)
                    .font(TigerDuckTheme.Typography.title)
                    .foregroundStyle(Color.textPrimary)
                Text(course.code)
                    .font(TigerDuckTheme.Typography.caption.monospaced())
                    .foregroundStyle(Color.textSecondary)
                Text(String(format: String(localized: "score_course_credits_meta"), displayTerm, (course.credits ?? 0).creditsText))
                    .font(TigerDuckTheme.Typography.caption)
                    .foregroundStyle(Color.textSecondary)
            }
            Spacer()
            Text(gradeDisplay)
                .font(.system(.largeTitle, design: .rounded).weight(.bold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(gradeColor)
        }
        .padding(TigerDuckTheme.Spacing.md)
        .presetCard(policy: appState.visualStylePolicy)
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
    }

    @ViewBuilder
    private func rosterSection(_ roster: SDCourse) -> some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.md) {
            if !roster.instructor.isEmpty {
                InfoRow(label: String(localized: "course_detail_instructor_label"), value: roster.instructor)
            }
            if roster.maxCount > 0 {
                InfoRow(
                    label: String(localized: "score_course_detail_enrollment_label"),
                    value: "\(roster.enrolledCount) / \(roster.maxCount)"
                )
            }
            let classroomText = SDCourse.dedup(roster.classroom)
            if !classroomText.isEmpty {
                InfoRow(label: String(localized: "course_detail_classroom_label"), value: classroomText)
            }
            let scheduleCode = formatScheduleCode(roster.schedule)
            if !scheduleCode.isEmpty {
                InfoRow(label: String(localized: "score_course_detail_schedule_label"), value: scheduleCode)
            }
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
    }

    private var unavailableCard: some View {
        HStack(spacing: TigerDuckTheme.Spacing.sm) {
            Image(systemName: "tray")
                .foregroundStyle(Color.textSecondary)
            Text(String(localized: "course_detail_no_roster"))
                .font(TigerDuckTheme.Typography.caption)
                .foregroundStyle(Color.textSecondary)
            Spacer()
        }
        .padding(TigerDuckTheme.Spacing.md)
        .presetCard(policy: appState.visualStylePolicy)
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
    }

    private var remarkSection: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.sm) {
            SectionHeader(title: String(localized: "score_info_note"))
                .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            Text(course.remark)
                .font(TigerDuckTheme.Typography.body)
                .foregroundStyle(Color.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(TigerDuckTheme.Spacing.md)
                .presetCard(policy: appState.visualStylePolicy)
                .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        }
    }

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

    /// Day-code mapping aligned with `CourseLookupService.parseNodeToSchedule`:
    ///   M=Mon · T=Tue · W=Wed · R=Thu · F=Fri · S=Sat · U=Sun
    /// Inverse direction here — turn `[weekday: [periods]]` back into the
    /// NTUST course-selection node string the school uses on its own pages.
    private static let dayCodes: [Int: String] = [
        1: "M", 2: "T", 3: "W", 4: "R", 5: "F", 6: "S", 7: "U"
    ]

    private func formatScheduleCode(_ schedule: [Int: [String]]) -> String {
        let order = AppConstants.Periods.chronologicalOrder
        let entries = schedule
            .sorted { $0.key < $1.key }
            .flatMap { weekday, periods -> [String] in
                guard let dayCode = Self.dayCodes[weekday] else { return [] }
                return periods
                    .sorted {
                        (order.firstIndex(of: $0) ?? Int.max) <
                        (order.firstIndex(of: $1) ?? Int.max)
                    }
                    .map { "\(dayCode)\($0)" }
            }
        return entries.joined(separator: ", ")
    }

    private var displayTerm: String {
        guard course.term.count == 4 else { return course.term }
        let year = String(course.term.prefix(3))
        let sem = String(course.term.suffix(1))
        let label = sem == "1"
            ? String(localized: "score_semester_first")
            : sem == "2"
                ? String(localized: "score_semester_second")
                : sem
        return "\(year) \(label)"
    }

    private var gradeDisplay: String {
        switch course.status {
        case .pending:  return String(localized: "score_grade_pending")
        case .withdrew: return String(localized: "score_grade_withdrew")
        case .exempted: return String(localized: "score_grade_exempted")
        case .passed:   return course.grade.isEmpty ? String(localized: "score_grade_passed") : course.grade
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
            return course.isPassStatusPassed ? Color(hex: 0x4ECDC4) : Color(hex: 0xE74C3C)
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

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
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
    }
}
