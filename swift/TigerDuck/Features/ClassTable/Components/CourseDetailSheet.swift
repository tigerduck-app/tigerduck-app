import SwiftUI

/// Modal detail for a single course row. Visual structure:
///   1. Color bar + course title (with optional Moodle jump button)
///   2. Two emphasis cards side-by-side: 教室 (classroom) | 時間 (time)
///   3. Flat InfoRow list: instructor / code / credits / enrollment
///   4. Outstanding assignments (unchanged)
///
/// The emphasis cards exist because classroom & time are the two fields users
/// glance at most often when tapping a course — they earn their own surface
/// instead of being buried in the same flat list as the metadata rows.
struct CourseDetailSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL

    let course: SDCourse
    let assignments: [SDAssignment]
    var timeRange: String? = nil
    var weekday: Int? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.lg) {
                    headerSection
                    emphasisCards
                    secondaryInfo
                    assignmentsSection
                }
                .padding(.top, TigerDuckTheme.Spacing.xl)
                .padding(.bottom, TigerDuckTheme.Spacing.lg)
            }
            .background(Color.backgroundPrimary)
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 360)
        #endif
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.lg) {
            HStack(alignment: .firstTextBaseline, spacing: TigerDuckTheme.Spacing.sm) {
                Text(course.displayName)
                    .font(.title.bold())
                    .foregroundStyle(Color.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if course.moodleDeepLink != nil {
                    Button(action: openMoodleCourse) {
                        Image(systemName: "arrow.up.right.square.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(Color.accentPrimary)
                    }
                    // TODO(l10n): add `course_detail_open_moodle_a11y` —
                    // "在 Moodle 開啟課程" / "Open course in Moodle"
                    // .accessibilityLabel(String(localized: "course_detail_open_moodle_a11y"))
                }
            }

            RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.sm)
                .fill(course.color)
                .frame(height: 6)
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
    }

    // MARK: - Emphasis cards

    private var emphasisCards: some View {
        HStack(spacing: TigerDuckTheme.Spacing.md) {
            EmphasisCard(
                label: String(localized: "course_detail_classroom_label"),
                value: classroomValue,
                policy: appState.visualStylePolicy
            )
            EmphasisCard(
                label: String(localized: "course_detail_time_label"),
                value: timeValue,
                policy: appState.visualStylePolicy
            )
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
    }

    /// Same resolution rule the previous flat layout used: per-weekday lookup
    /// when we know which day this row represents, otherwise the deduped
    /// aggregate string. Empty results render as an em-dash placeholder so
    /// the card always has visible content.
    private var classroomValue: String {
        let resolved = weekday.map { course.classroom(for: $0) } ?? SDCourse.dedup(course.classroom)
        return resolved.isEmpty ? "—" : resolved
    }

    /// Prefer the explicit time range supplied by the caller (ClassTable
    /// knows the precise slot). When omitted — e.g. HomeView's TimeSlider
    /// only hands us the weekday — derive it from the course schedule for
    /// that weekday so the card never collapses to a dash unnecessarily.
    private var timeValue: String {
        if let timeRange, !timeRange.isEmpty { return timeRange }
        if let weekday, let derived = course.timeRange(for: weekday) { return derived }
        return "—"
    }

    // MARK: - Secondary info

    private var secondaryInfo: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.md) {
            InfoRow(
                label: String(localized: "course_detail_instructor_label"),
                value: course.instructor.isEmpty ? "—" : course.instructor
            )
            InfoRow(
                label: String(localized: "course_detail_code_label"),
                value: course.courseNo
            )
            InfoRow(
                label: String(localized: "course_detail_credits_label"),
                value: "\(course.credits)"
            )
            InfoRow(
                label: String(localized: "course_detail_enrollment_label"),
                value: "\(course.enrolledCount) / \(course.maxCount)"
            )
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
    }

    // MARK: - Assignments (preserved exactly as before)

    @ViewBuilder
    private var assignmentsSection: some View {
        if !assignments.isEmpty {
            Divider().background(Color.textSecondary)
                .padding(.horizontal, TigerDuckTheme.Spacing.lg)

            Text(String(localized: "course_detail_incomplete_assignments"))
                .font(TigerDuckTheme.Typography.headline)
                .foregroundStyle(Color.textPrimary)
                .padding(.horizontal, TigerDuckTheme.Spacing.lg)

            ForEach(Array(assignments.enumerated()), id: \.element.assignmentId) { _, assignment in
                Button {
                    if let url = assignment.moodleDeepLink {
                        openURL(url)
                    }
                } label: {
                    HStack {
                        Image(systemName: "doc.text")
                            .foregroundStyle(Color.accentPrimary)
                        VStack(alignment: .leading) {
                            Text(assignment.displayTitle)
                                .font(TigerDuckTheme.Typography.body)
                                .foregroundStyle(Color.textPrimary)
                            Text(String(format: String(localized: "course_detail_due_prefix"), assignment.dueDate.shortDateString))
                                .font(TigerDuckTheme.Typography.caption)
                                .foregroundStyle(assignment.isOverdue ? Color.badgeRed : Color.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .foregroundStyle(Color.textSecondary)
                            .font(.caption)
                    }
                }
                .buttonStyle(.plain)
                .cardPadding()
                .glassCard()
                .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            }
        }
    }

    // MARK: - Actions

    /// Always route through the `moodlemobile://` deep link — matches the
    /// assignment-row convention above and keeps the user inside the Moodle
    /// app instead of bouncing out to Safari. `openURL` falls back to the
    /// system browser on macOS when no Moodle app is installed.
    private func openMoodleCourse() {
        guard let deepLink = course.moodleDeepLink else { return }
        openURL(deepLink)
    }
}

// MARK: - Emphasis card

/// Big-text card used for the two fields that earn visual emphasis
/// (classroom and time). Label sits small on top, value renders large
/// with a rounded display font so the two cards read as a single
/// at-a-glance pair.
private struct EmphasisCard: View {
    let label: String
    let value: String
    let policy: VisualStylePolicy

    var body: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.xs) {
            Text(label)
                .font(TigerDuckTheme.Typography.caption)
                .foregroundStyle(Color.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity)
        .padding(TigerDuckTheme.Spacing.md)
        .presetCard(policy: policy)
    }
}

// MARK: - Label/value row

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
