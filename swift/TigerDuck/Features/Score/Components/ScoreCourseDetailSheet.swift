import SwiftUI
import TigerDuckCore

struct ScoreCourseDetailSheet: View {
    let course: CourseGrade
    let policy: VisualStylePolicy
    var courses: CourseStore = .shared

    @State private var rosterCourse: CourseRoster?
    @State private var detent: PresentationDetent = .medium

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.lg) {
                headerCard
                infoRows
                if rosterCourse == nil {
                    unavailableCard
                }
                if !course.remark.isEmpty {
                    remarkSection
                }
            }
            .padding(.top, TigerDuckTheme.Spacing.xl)
            .padding(.bottom, TigerDuckTheme.Spacing.lg)
        }
        .background(Color.backgroundPrimary)
        .flickClosesSheet(at: detent)
        .toastHost()
        .presentationDetents([.medium, .large], selection: $detent)
        .onAppear(perform: resolveRosterCourse)
    }

    private var headerCard: some View {
        HStack(alignment: .center, spacing: TigerDuckTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text(course.name)
                    .font(TigerDuckTheme.Typography.title)
                    .foregroundStyle(Color.textPrimary)
                Text(displayTerm)
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
        .presetCard(policy: policy)
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
    }

    private var infoRows: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.md) {
            if let rosterCourse {
                CopyableDetailRow.instructor(rosterCourse.instructor)
            }
            CopyableDetailRow.code(course.code)
            DetailInfoRow(
                label: String(localized: "course_detail_credits_label"), value: course.credits.map(\.creditsText) ?? "—"
            )
            if let rosterCourse {
                if rosterCourse.maxCount > 0 {
                    DetailInfoRow(
                        label: String(localized: "score_course_detail_enrollment_label"),
                        value: "\(rosterCourse.enrolledCount) / \(rosterCourse.maxCount)"
                    )
                }
                CopyableDetailRow.location(rosterCourse.classroom)
                let scheduleCode = formatScheduleCode(rosterCourse.schedule)
                if !scheduleCode.isEmpty {
                    DetailInfoRow(label: String(localized: "score_course_detail_schedule_label"), value: scheduleCode)
                }
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
        .presetCard(policy: policy)
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
                .presetCard(policy: policy)
                .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        }
    }

    private func resolveRosterCourse() {
        guard rosterCourse == nil else { return }
        rosterCourse = CourseRoster.find(courseNo: course.code, term: course.term, in: courses)
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
        guard case let (year, sem)? = AcademicTerm.displayParts(of: course.term) else { return course.term }
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
            return TigerDuckTheme.Tint.skyBlue
        case .passed:
            return course.isPassStatusPassed ? TigerDuckTheme.Tint.teal : TigerDuckTheme.Tint.red
        case .graded:
            return ScoreColor.grade(course.grade)
        }
    }
}
